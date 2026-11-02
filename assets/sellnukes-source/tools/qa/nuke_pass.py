#!/usr/bin/env python3
"""
nuke_pass.py — Studio QA for the R78 Nuke Pass (P-pass; spec
docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md §2, docs/nuke-pass.md). One SOLO
playtest in the open place (hold the Studio lock; never multiplayer, owner R72). Prints one JSON
record; captures go to docs/verification/r78-pass/.

Steps:
    1. start a solo Play playtest, wait for the HUD + the first profile push
    2. BEFORE Season 1 (real clock): the screen shows the "starts soon" overlay + countdown; no
       HUD Pass offer
    3. Studio pass clock +5 days (Season 1 running): fresh state, HUD Pass offer shown, 1,300 XP →
       tier 3; device matrix of the track (desktop / phone / tablet / console)
    4. CLAIM tier 1 by a real click (server claim as fallback), a repeat claim pays nothing,
       hostile PassClaim / PassClaimAll arguments change nothing
    5. premium through the REAL receipt path (simulateReceiptAsync): unlocks the season; the same
       PurchaseId again pays nothing (ledger); a second purchase pays the 500-gem fallback
    6. restricted region: a premium spins tier pays gems instead of spins
    7. CLAIM ALL (juice capture), then tier 30 + 2 bonus chests → CLAIM ALL pays the exclusives
       (SEASON 1 + NUKE PASS titles, Harvest Glow trail, Golden Nukey or its fallback gems)
    8. gamepad default selection; the track at tier 30 (matrix)
    9. season end: XP left unclaimed, clock +31 days → auto-granted on settle, overlay "Season 2"
   10. restore the Studio profile + clock, stop the playtest
Usage:
    python3 scripts/studio-lock.py acquire P-pass
    STUDIO_LOCK_OWNER=P-pass python3 tools/qa/nuke_pass.py          # everything
    STUDIO_LOCK_OWNER=P-pass python3 tools/qa/nuke_pass.py shots    # only the tier-3 device matrix
    python3 scripts/studio-lock.py release P-pass
"""
from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402
import world_tour  # noqa: E402  (require_lock, render, result, stop_playtest)

SERVER = (ROOT / "tools/qa/nuke_pass_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/nuke_pass_client.luau").read_text()
SERVER_COMMANDS = {"prepare", "xp", "claim", "claimall", "receipt", "policy", "clock", "status", "restore"}
CLIENT_COMMANDS = {"diag", "close_all", "open", "state", "point", "garbage", "fire_claim", "fire_all", "pad_on", "pad_off",
                   "reopen", "close"}
OUT = ROOT / "docs/verification/r78-pass"

# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def server(command: str, args: list[float] | None = None) -> dict:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return json.loads(world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code})))


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def capture(name: str) -> str:
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 88}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not images:
        return "capture failed"
    path = OUT / name
    path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
    return str(path)


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(DEVICES, images):
        name = f"{prefix}-{device['label']}.jpg"
        (OUT / name).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str(OUT / name))
    if not images:
        names.append("matrix failed: " + json.dumps(response)[:300])
    return names


def screenshot_width() -> int:
    import io
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


def shots_only() -> int:
    """`nuke_pass.py shots`: only the track captures (tier 3, device matrix) — a quick layout check."""
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {}
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:120])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)
        client("close_all")
        server("prepare", [5])
        server("xp", [1300])
        time.sleep(1.0)
        record["state"] = json.loads(client("open"))
        record["shots"] = matrix("nukepass-tier3")
    finally:
        try:
            record["restore"] = server("restore")
        except Exception as error:
            record["restore"] = {"error": str(error)[:200]}
        world_tour.stop_playtest()
    print(json.dumps(record, indent=1))
    return 0 if record["restore"].get("restored") else 1


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "shots":
        return shots_only()
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": [], "checks": {}}
    log = record["log"].append
    checks = record["checks"]
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)  # first profile push + boot windows
        client("close_all")
        # 2. Before Season 1 (real clock, today 2026-10-31).
        before = server("prepare", [0])
        checks["beforeNoSeason"] = before["activeSeason"] == "" and before["season"] == ""
        time.sleep(1.0)
        record["beforeState"] = json.loads(client("open"))
        checks["beforeOverlay"] = record["beforeState"]["overlay"] and not record["beforeState"]["offer"]
        record["beforeShot"] = capture("nukepass-before-season.jpg")
        client("close")
        # 3. Season 1 running (+5 days).
        running = server("prepare", [5])
        checks["joinedSeason"] = running["season"] == "harvest1" and running["xp"] == 0
        time.sleep(1.2)
        time.sleep(1.0)
        checks["offerShown"] = json.loads(client("diag"))["offer"]
        xp = server("xp", [1300])
        checks["tier3"] = xp["tier"] == 3 and xp["added"] == 1300 and xp["claimable"] == 3
        time.sleep(1.0)
        record["tier3State"] = json.loads(client("open"))
        record["tier3Shots"] = matrix("nukepass-tier3")
        # 4. CLAIM tier 1 by a real click.
        point = json.loads(client("point", [2, 1]))
        log("click " + click(point))
        time.sleep(1.5)
        status = server("status")
        record["clickLanded"] = 1 in status["claimedFree"]
        if not record["clickLanded"]:
            # The simulated click missed: send the same intent through the REAL remote.
            client("fire_claim", [1, 1])
            time.sleep(1.5)
            status = server("status")
        checks["tier1Claimed"] = 1 in status["claimedFree"]
        repeat = server("claim", [1, 1])
        checks["repeatPaysNothing"] = repeat["grants"] == 0 and repeat["gemsDelta"] == 0
        gems_before = repeat["gems"]
        client("garbage")
        time.sleep(1.5)
        after_garbage = server("status")
        checks["garbageIgnored"] = (after_garbage["claimedFree"] == repeat["claimedFree"]
                                    and after_garbage["gems"] == gems_before and not after_garbage["premium"])
        # 5. Premium via the real receipt path.
        receipt = server("receipt", [1])
        checks["premiumGranted"] = receipt["premium"] and receipt["premiumClaimable"] == 3 and receipt["gemsDelta"] == 0
        again = server("receipt", [1])
        checks["sameReceiptIdempotent"] = again["gemsDelta"] == 0 and again["premium"]
        second = server("receipt", [2])
        checks["secondPurchaseFallback"] = second["gemsDelta"] == 500
        # 6. Restricted region: premium tier 3 = 2 spins → 80 gems, no paid spins.
        server("policy", [1])
        restricted = server("claim", [2, 3])
        checks["restrictedSpinsAsGems"] = restricted["grants"] == 1 and restricted["gemsDelta"] == 80
        server("policy", [0])
        time.sleep(0.8)
        # 7. CLAIM ALL (juice), then tier 30 + chests (anything that popped over the window closes).
        client("close_all")
        time.sleep(0.4)
        record["preClaimAll"] = json.loads(client("open"))
        point = json.loads(client("point", [1]))
        log("claim-all click " + click(point))
        time.sleep(0.35)
        record["claimAllShot"] = capture("nukepass-claim-juice.jpg")
        time.sleep(1.5)
        status = server("status")
        record["claimAllClickLanded"] = status["claimable"] == 0
        if status["claimable"] > 0:
            client("fire_all")  # the click missed: the same intent through the REAL remote
            time.sleep(1.5)
            status = server("status")
        checks["claimAllEmptied"] = status["claimable"] == 0
        top = server("xp", [12000 + 1700 - status["xp"]])
        checks["tier30Chests"] = top["tier"] == 30 and top["claimable"] >= 50
        final = server("claimall")
        checks["exclusives"] = ("season1" in final["titles"] and "nukePass" in final["titles"]
                                and "harvest_glow" in final["trails"])
        checks["chestsClaimed"] = final["overflow"] == 2
        record["final"] = final
        time.sleep(2.0)
        client("close_all")  # the Golden Nukey reveal popup
        time.sleep(0.4)
        record["tier30State"] = json.loads(client("open"))
        record["tier30Shots"] = matrix("nukepass-tier30")
        # 8. Gamepad default selection.
        log("pad " + client("pad_on"))
        server("xp", [800])  # one chest claimable → the default selection is the chest
        time.sleep(0.8)
        record["padDefault"] = client("reopen")
        log("pad off " + client("pad_off"))
        client("close")
        # 9. Season end: leave rewards unclaimed, then +31 days → auto-granted.
        server("prepare", [5])
        server("xp", [2000])
        ended = server("clock", [31])
        checks["autoGranted"] = (ended["claimable"] == 0 and len(ended["claimedFree"]) == 5
                                 and ended["season"] == "harvest1" and ended["gemsDelta"] > 0)
        time.sleep(1.0)
        record["afterState"] = json.loads(client("open"))
        checks["afterOverlay"] = record["afterState"]["overlay"] and not record["afterState"]["offer"]
        record["afterShot"] = capture("nukepass-after-season.jpg")
        client("close")
    finally:
        try:
            record["restore"] = server("restore")
        except Exception as error:
            record["restore"] = {"error": str(error)[:200]}
        world_tour.stop_playtest()
    record["passed"] = all(bool(v) for v in checks.values())
    print(json.dumps(record, indent=1))
    return 0 if record["passed"] and record["restore"].get("restored") else 1


if __name__ == "__main__":
    raise SystemExit(main())
