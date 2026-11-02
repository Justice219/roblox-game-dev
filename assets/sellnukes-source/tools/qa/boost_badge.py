#!/usr/bin/env python3
"""
boost_badge.py — Studio QA for the R82 boost badge (B-boost: the cash counter's corner sticker,
src/client/UI/Screens/BoostChips/BoostChipsScreen.luau + src/client/Social/BoostChipLogic.luau +
the BoostCorner anchor in src/client/UI/Hud/HudCurrency.luau). One SOLO playtest in the open
place (owner R72: never multiplayer; hold the Studio lock).

Steps (prints one JSON record + a check list; captures under docs/verification/r82-*):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running; start a solo
       Play playtest, wait for the HUD, close the boot windows
    2. 2x Cash for 85 s (the owner's screenshot: "2x CASH 1:25") through BoostService.grant ->
       per-device diag (set_device_simulator: desktop / phone / tablet / console) + device matrix
       r82-badge-cash2x-*
    3. + Rookie Rush + Server 2x + Friend Boost (display push) -> 9.6x, stacked sticker ->
       per-device diag + matrix r82-badge-stacked-*
    4. gamepad-select the badge -> breakdown card -> per-device diag + matrix r82-breakdown-*
    5. width probe (display only): "$0", "$608.05Sx", "$888.88Dc" in the counter -> clearance
       per device (the tilted sticker must stay right of the digits' box) + matrix r82-badge-long-*
    6. cleanup (rush cleared, server boost stopped, friends reset, the test's cash2x removed),
       stop the playtest

Usage:
    python3 scripts/studio-lock.py acquire B-boost
    STUDIO_LOCK_OWNER=B-boost python3 tools/qa/boost_badge.py
    python3 scripts/studio-lock.py release B-boost
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

SERVER = (ROOT / "tools/qa/boost_badge_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/boost_badge_client.luau").read_text()
SERVER_COMMANDS = {"status", "grant_cash", "grant_rookie", "server_on", "server_off", "fake_friends", "no_friends",
                   "cleanup"}
CLIENT_COMMANDS = {"diag", "select", "deselect", "long", "close_all"}
OUT = ROOT / "docs/verification"
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def server(command: str, args: list[float] | None = None) -> dict:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return safe_json(world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code})))


def client(command: str, args: list[float] | None = None) -> dict:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return safe_json(world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code})))


def safe_json(raw: str) -> dict:
    try:
        value = json.loads(raw)
        return value if isinstance(value, dict) else {"raw": raw}
    except json.JSONDecodeError:
        return {"raw": raw}


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.2,
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


def per_device(command: str, args: list[float] | None = None) -> dict:
    """Runs a client command under each emulated device (then stops the simulation)."""
    out = {}
    try:
        for device in DEVICES:
            settings = {"target": "client-1", "deviceId": device["deviceId"]}
            if "orientation" in device:
                settings["orientation"] = device["orientation"]
            studio_mcp.call_tool("set_device_simulator", settings)
            time.sleep(2.0)
            out[device["label"]] = client(command, args)
    finally:
        studio_mcp.call_tool("set_device_simulator", {"target": "client-1", "stopSimulation": True})
        time.sleep(1.0)
    return out


def wait_until(predicate, seconds: float, every: float = 1.5):
    deadline = time.time() + seconds
    last = None
    while time.time() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except Exception as error:  # VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(every)
    return None


def main() -> int:
    world_tour.require_lock()
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    try:
        running = json.loads(status).get("running") is True
    except (json.JSONDecodeError, AttributeError):
        running = True  # unknown state (no Studio peer?): never start on top of someone's playtest
    if running:
        raise SystemExit(f"a playtest is already running or Studio is unreachable (not ours): {status[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    had_cash = True
    try:
        record["ready"] = wait_until(lambda: (lambda d: d if d.get("anchorParent") else None)(client("diag")), 150)
        time.sleep(8)  # first profile push + join queue (loading, plot reveal, tutorial card)
        client("close_all")
        time.sleep(1.0)
        before = server("status")
        record["before"] = before
        had_cash = bool((before.get("boosts") or {}).get("cash2x"))
        # 2. The owner's case: 2x Cash, 1:25 left.
        record["grantCash"] = server("grant_cash", [85])
        time.sleep(1.5)
        record["cash2x"] = per_device("diag")
        record["cash2xShots"] = matrix("r82-badge-cash2x")
        # 3. Stacked: rookie + server + friends on top.
        server("grant_rookie", [761])
        server("server_on", [600])
        server("fake_friends")
        time.sleep(1.5)
        client("close_all")  # the server boost's thank-you toast is not a window, but be safe
        record["stacked"] = per_device("diag")
        record["stackedShots"] = matrix("r82-badge-stacked")
        # 4. Breakdown (gamepad selection opens it).
        record["select"] = client("select")
        record["breakdown"] = per_device("select")
        record["breakdownShots"] = []
        client("select")
        record["breakdownShots"] = matrix("r82-breakdown")
        record["deselect"] = client("deselect")
        # 5. Width probe (display only).
        record["long"] = {}
        for which, label in ((1, "zero"), (2, "sx"), (3, "dc")):
            record["long"][label] = per_device("long", [which])
        client("long", [3])
        record["longShots"] = matrix("r82-badge-long")
        record["restore"] = client("long", [4])
    except Exception as error:  # keep the partial record: it is the diagnosis
        record["error"] = repr(error)[:500]
    finally:
        try:
            record["cleanup"] = server("cleanup", [0 if had_cash else 1])
        except Exception as error:
            record["cleanupError"] = repr(error)[:300]
        world_tour.stop_playtest()

    def every(group: dict | None, test) -> bool:
        return bool(group) and all(test(v) for v in group.values() if isinstance(v, dict))

    cash = record.get("cash2x") or {}
    stacked = record.get("stacked") or {}
    breakdown = record.get("breakdown") or {}
    long = record.get("long") or {}
    clear = lambda d: (d.get("clearance") or {}).get("clearPx", -1) > (d.get("clearance") or {}).get("outlinePx", 99)
    checks = {
        "no error": "error" not in record,
        "2x Cash badge reads 2x": every(cash, lambda d: d.get("visible") and d.get("big") == "2x"),
        "timer under 1:26": every(cash, lambda d: (d.get("small") or "9").startswith("1:2")),
        "badge sits on the cash counter": every(cash, lambda d: d.get("anchorParent") == "Money_cash"),
        "badge clear of the digits (2x)": every(cash, clear),
        "timer text >= 14 pt": every(cash, lambda d: (d.get("smallH") or 0) >= 14),
        "hit area >= 44 pt": every(cash, lambda d: min((d.get("hit") or {}).get("w", 0), (d.get("hit") or {}).get("h", 0)) >= 44),
        "clear of the Roblox top bar": every(cash, lambda d: not d.get("topbarHit")),
        "no Boosts zone published": every(cash, lambda d: d.get("boostsZone") is None),
        "stacked: 9.6x + back sticker": every(stacked, lambda d: d.get("big") == "9.6x" and d.get("back")),
        "stacked clear of the digits": every(stacked, clear),
        "gamepad: in the HUD D-pad graph": every(stacked, lambda d: d.get("entryUp") == "BoostBadge" and d.get("navLeft")),
        "breakdown opens with 4 rows": every(breakdown, lambda d: d.get("panelOpen") and len(d.get("rows") or []) == 4),
        "breakdown text >= 14 pt": every(breakdown, lambda d: all((r.get("nameH") or 0) >= 14 for r in d.get("rows") or [])),
        "breakdown inside the viewport": every(breakdown, lambda d: d.get("panel") and d["panel"]["x"] >= 0
                                               and d["panel"]["x"] + d["panel"]["w"] <= d["viewport"]["x"]
                                               and d["panel"]["y"] + d["panel"]["h"] <= d["viewport"]["y"]),
        "deselect closes it": not (record.get("deselect") or {}).get("panelOpen", True),
        "clear of the digits at every width": all(every(long.get(k), clear) for k in ("zero", "sx", "dc")),
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1, default=str))
    failed = [name for name, ok in checks.items() if not ok]
    print("FAILED: " + ", ".join(failed) if failed else "ALL CHECKS PASSED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
