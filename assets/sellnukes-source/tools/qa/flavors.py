#!/usr/bin/env python3
"""
flavors.py — Studio QA for owner R89 Surprise Batches + Flavour Book + Big Pop
(src/server/Tycoon/{FlavorService, BigPop, FlavorAdmin}, src/client/Tycoon/{FlavorController,
Fx/FlavorPops, Fx/FlavorGlow, Fx/BigPopBanner}, src/client/UI/Screens/{FlavorReveal, FlavorBook}).
One solo playtest in the open place (hold the Studio lock; never run while someone else's playtest
is going). Re-runnable: the server prep clears the player's Flavour Book first.

Steps (prints one JSON record; captures under docs/verification/r89-flavors/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the HUD + profile
    3. server prep: tutorial done, Garage Lab pads to Uncle Atom (Workbench automated), flavours ON
       x1 + Big Pop ON, the Book cleared; client closes every window (the reveal gate)
    4. Glitter (forced through the admin seam = the real pipeline): camera on the Workbench ->
       the tinted pop + flavour word + sparkle -> desktop shot; controller counted the FlavorPop
    5. Rainbow (forced): the producer glow (every player in the world) -> desktop shot
    6. Galaxy (forced): DebugHold on the reveal -> FlavorHighlight opens the reveal -> desktop shot
       + device matrix (phone / tablet / console) -> release; server Big Pop counters moved
    7. the Big Pop banner (sample broadcast, held) -> desktop shot + device matrix
    8. Book: seed more entries -> Pets window (the FLAVOURS button + "!" badge) shot -> REAL press of
       FLAVOURS (handoff) -> Book probe (15 tiles, states, default selection, sizes) -> desktop shot
       + device matrix -> REAL press of CLAIM ALL -> gems went up, rewards claimed -> claimed shot;
       LUCK x2 chip shot (admin odds x2), odds back to x1
    9. stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire F-flavors
    STUDIO_LOCK_OWNER=F-flavors python3 tools/qa/flavors.py
    python3 scripts/studio-lock.py release F-flavors
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

CLIENT = (ROOT / "tools/qa/flavors_client.luau").read_text()
SERVER = (ROOT / "tools/qa/flavors_server.luau").read_text()
CLIENT_COMMANDS = {"diag", "closeall", "hold", "release", "probe", "focus", "unfocus", "pets", "book",
                   "claimpoint", "bigpop", "preview"}
SERVER_COMMANDS = {"prep", "force", "seed", "luck", "status"}
OUT = ROOT / "docs/verification/r89-flavors"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active"). The desktop
# entry comes last and restoreAfter is off (defense_towers.py lesson: a stale simulator state makes
# the restore step fail with "orientation can only be set on mobile devices").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
    {"label": "desktop", "deviceId": "hd_1080"},
]
GLITTER, RAINBOW, GALAXY = 2, 3, 4


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


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.2,
        "restoreAfter": False,
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
    if not point or "x" not in point:
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


def wait_stat(key: str, above: int, seconds: float) -> dict:
    """Polls the client's FlavorController counters until `key` passes `above`."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        last = as_json(client("probe"))
        if (last.get("stats") or {}).get(key, 0) > above:
            return last
        time.sleep(0.3)
    return last


def runtime_errors() -> list[str]:
    """Client / server log lines from the flavour modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
    keys = ("Flavor", "BigPop", "IncomePops", "PetsScreen", "PetController", "[Sound]")
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
        time.sleep(4)  # plot assignment + first profile push
        record["prep"] = as_json(server("prep"))
        time.sleep(3)  # the granted builds + the TutorialState push
        log("closeall " + client("closeall"))
        record["diag"] = as_json(client("diag"))

        # Glitter: the real pipeline (forced batch → FlavorPop reaches the client), then the same
        # look replayed on the focused producer for the shot (the forced batch lands on whichever
        # producer pays first, maybe off camera).
        log("focus " + client("focus"))
        time.sleep(1.0)
        before = (record["diag"].get("stats") or {}).get("pops", 0)
        log("force glitter " + server("force", [GLITTER]))
        record["glitter"] = wait_stat("pops", before, 6)
        time.sleep(1.2)
        log("preview glitter " + client("preview", [GLITTER]))
        time.sleep(0.35)
        record["glitterShot"] = shot("r89-flavors-pop-glitter")

        # Rainbow: the producer glow (real forced batch → FlavorGlow to the world), then on camera.
        glows = (record["glitter"].get("stats") or {}).get("glows", 0)
        log("force rainbow " + server("force", [RAINBOW]))
        record["rainbow"] = wait_stat("glows", glows, 6)
        time.sleep(1.2)
        log("preview rainbow " + client("preview", [RAINBOW]))
        time.sleep(0.9)
        record["rainbowShot"] = shot("r89-flavors-glow-rainbow")
        log("unfocus " + client("unfocus"))
        time.sleep(2.0)

        # Galaxy: the reveal (held for the device matrix) + a real Big Pop broadcast.
        log("closeall " + client("closeall"))
        log("hold " + client("hold"))
        reveals = (record["rainbow"].get("stats") or {}).get("reveals", 0)
        log("force galaxy " + server("force", [GALAXY]))
        record["galaxy"] = wait_stat("reveals", reveals, 8)
        time.sleep(1.4)  # bars + card + odds count-up
        record["revealShot"] = shot("r89-flavors-reveal-desktop")
        record["revealDevices"] = matrix("r89-flavors-reveal")
        log("release " + client("release"))
        time.sleep(1.0)
        record["afterReveal"] = as_json(server("status"))
        record["afterRevealClient"] = as_json(client("probe"))

        # Big Pop banner (sample broadcast held 30 s for the captures).
        log("bigpop " + client("bigpop"))
        time.sleep(0.6)
        record["bigPopShot"] = shot("r89-flavors-bigpop-desktop")
        record["bigPopDevices"] = matrix("r89-flavors-bigpop")

        # Flavour Book through the Pets window.
        record["seed"] = as_json(server("seed"))
        time.sleep(1.5)
        record["pets"] = as_json(client("pets"))
        record["petsShot"] = shot("r89-flavors-pets-button")
        log("press FLAVOURS " + click(record["pets"].get("point") or {}))
        record["book"] = as_json(client("book"))
        record["bookShot"] = shot("r89-flavors-book-desktop")
        record["bookDevices"] = matrix("r89-flavors-book")
        gems_before = record["book"].get("gems")
        log("press CLAIM ALL " + click(as_json(client("claimpoint"))))
        time.sleep(2.0)
        record["claimed"] = as_json(client("book"))
        record["claimedServer"] = as_json(server("status"))
        record["gems"] = {"before": gems_before, "after": record["claimed"].get("gems")}
        record["claimedShot"] = shot("r89-flavors-book-claimed")
        record["luck"] = as_json(server("luck", [2]))
        time.sleep(1.5)
        record["luckBook"] = as_json(client("book"))
        record["luckShot"] = shot("r89-flavors-book-luck")
        log("luck reset " + server("luck", [1]))
        record["logIssues"] = runtime_errors()
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    print(json.dumps(record, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
