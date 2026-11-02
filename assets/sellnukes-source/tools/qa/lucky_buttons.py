#!/usr/bin/env python3
"""
lucky_buttons.py — Studio QA for the Lucky Buttons (owner R69: src/server/Services/
LuckyButtonService.luau + src/client/LuckyButtons/LuckyButtonClient.luau + the edge arrow
src/client/UI/Screens/LuckyButtons/LuckyArrowScreen.luau). One solo playtest in the open place
(hold the Studio lock).

Steps (prints one JSON record; screenshots under docs/verification/lucky-buttons/):
    1. start a solo Play playtest, wait for the HUD, close the boot windows
    2. interval x0.25, stand on the own plot -> the NATURAL schedule must spawn the first button
       (a FREE kind: the first button of a session is always free) within ~40 s
    3. the client draws it (model + label); camera on it -> capture desktop / phone / tablet / console
    4. camera away -> the edge arrow shows -> capture the matrix again
    5. walk ONTO it (real client walk-in detection -> LuckyButtonClaim) -> claimed, removed,
       cash grows for a cash kind
    6. admin seam: spawn a PAID "boost30" button, walk onto it -> owner R122: NO purchase prompt
       opens on walk-in (status.prompted unchanged); the DEAL card shows instead (status.dealShown
       grows, the client reports "shown") -> one screenshot of the DEAL card
    7. reset (interval 1, clear) and stop the playtest

Usage:
    python3 scripts/studio-lock.py acquire H3-hub
    STUDIO_LOCK_OWNER=H3-hub python3 tools/qa/lucky_buttons.py
    python3 scripts/studio-lock.py release H3-hub
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
import world_tour  # noqa: E402  (require_lock, render, result)

SERVER = (ROOT / "tools/qa/lucky_buttons_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/lucky_buttons_client.luau").read_text()
SERVER_COMMANDS = {"setup", "to_plot", "status", "near_button", "to_button", "spawn", "cash", "reset"}
CLIENT_COMMANDS = {"diag", "look_button", "look_away", "camera_reset", "close_all"}
OUT = ROOT / "docs/verification/lucky-buttons"
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
KIND_BOOST30 = 4  # LuckyButtonConfig.KindIds index of "boost30"


def server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def status() -> dict:
    return json.loads(server("status"))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 0.8,
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


def screenshot(name: str) -> str:
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 88}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not images:
        return "screenshot failed: " + json.dumps(response)[:200]
    path = OUT / name
    path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
    return str(path)


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


def safe_json(raw: str) -> dict:
    """A probe answer as a dict ({"raw": text} when it is not JSON, e.g. "none")."""
    try:
        value = json.loads(raw)
        return value if isinstance(value, dict) else {"raw": raw}
    except json.JSONDecodeError:
        return {"raw": raw}


def fresh(kind_index: int) -> dict:
    """Clears every button and spawns one of a kind (admin seam) for the next step. Interval x10
    keeps the natural schedule (re-armed by the clear) from dropping a button mid-step."""
    server("reset")
    server("setup", [10])
    return safe_json(server("spawn", [kind_index]))


def main() -> int:
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_until(lambda: safe_json(client("diag")).get("hud") and safe_json(client("diag")), 150)
        time.sleep(6)  # first profile push + boot windows
        client("close_all")
        record["setup"] = safe_json(server("setup", [0.25]))
        log("to_plot " + server("to_plot"))
        # 1. The NATURAL schedule (x0.25): first button 11–19 s after arriving, always free.
        record["natural"] = wait_until(lambda: (lambda s: s if s["buttons"] else None)(status()), 45)
        time.sleep(1.0)
        record["clientAfterNatural"] = safe_json(client("diag"))
        # 2. Captures with a fresh cash button: camera on it, then looking away (edge arrow).
        record["spawnCash"] = fresh(1)
        time.sleep(1.0)
        log("near " + server("near_button", [16]))
        record["clientAfterSpawn"] = safe_json(client("diag"))
        record["lookButton"] = safe_json(client("look_button", [24]))
        record["spawnScreens"] = matrix("spawn")
        record["spawnBoost"] = fresh(2)
        time.sleep(1.0)
        log("near " + server("near_button", [16]))
        record["arrowAway"] = safe_json(client("look_away"))
        record["arrowScreens"] = matrix("arrow")
        client("camera_reset")
        # 3. Walk-in FREE claim (cash): the real client detection sends LuckyButtonClaim.
        record["claimSpawn"] = fresh(1)
        time.sleep(1.0)
        cash_before = float(server("cash"))
        claimed_before = status()["status"]["claimed"]
        log("to_button " + server("to_button"))
        time.sleep(2.5)
        after = status()
        record["afterClaim"] = after
        record["cash"] = {"before": cash_before, "after": float(server("cash"))}
        record["clientAfterClaim"] = safe_json(client("diag"))
        record["claimedDelta"] = after["status"]["claimed"] - claimed_before
        # 4. Walk-in PAID button (boost30) -> owner R122: the DEAL card, never a walk-in prompt.
        record["paidSpawn"] = fresh(KIND_BOOST30)
        time.sleep(1.0)
        before_paid = status()["status"]
        log("to_paid " + server("to_button"))
        time.sleep(2.5)
        record["dealShot"] = screenshot("paid-deal-card.jpg")
        record["afterPaid"] = status()
        record["promptedDelta"] = record["afterPaid"]["status"]["prompted"] - before_paid["prompted"]
        record["dealShownDelta"] = record["afterPaid"]["status"].get("dealShown", 0) - before_paid.get(
            "dealShown", 0
        )
        log("reset " + server("reset"))
    except Exception as error:  # keep the partial record: it is the diagnosis
        record["error"] = repr(error)[:500]
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])

    natural = record.get("natural") or {"buttons": []}
    first_kind = natural["buttons"][0]["kind"] if natural.get("buttons") else None
    spawn_diag = record.get("clientAfterSpawn") or {}
    claim_diag = record.get("clientAfterClaim") or {}
    cash = record.get("cash") or {"before": 0, "after": 0}
    checks = {
        "no error": "error" not in record,
        "natural spawn within 45 s": first_kind is not None,
        "first button of the session is free": first_kind in ("cash", "boost2x", "speed2x"),
        "client drew it": spawn_diag.get("live", 0) >= 1 and spawn_diag.get("models", 0) >= 1,
        "edge arrow shows when looking away": bool((record.get("arrowAway") or {}).get("visible")),
        "walk-in claim": record.get("claimedDelta", 0) >= 1 and claim_diag.get("live", 1) == 0,
        "cash grew": cash["after"] > cash["before"],
        "paid spawn": bool((record.get("paidSpawn") or {}).get("ok")),
        # R122: a paid walk-in never opens a Robux prompt; it shows the DEAL card (not in New
        # Player Mode, where paid buttons never spawn).
        "paid walk-in opens no prompt": record.get("promptedDelta", 1) == 0,
        "paid walk-in shows the DEAL card (not in New Player Mode)": bool((record.get("setup") or {}).get("npm"))
        or record.get("dealShownDelta", 0) >= 1,
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
