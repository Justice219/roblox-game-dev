#!/usr/bin/env python3
"""
kinetic.py — Studio QA for owner R90's Mega Lever + Tip Jar (K-kinetic: src/server/Kinetic/*,
src/client/Kinetic/*, src/shared/Config/KineticConfig.luau; docs/kinetic.md). One solo playtest in
the open place (hold the Studio lock; never run while someone else's playtest is going). Re-runnable:
every step goes through the real service code and the admin seams, and the run ends with a reset.

Steps (prints one JSON record; captures under docs/verification/r90-kinetic/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the HUD + profile, close the boot windows
    3. server: switches ON, grant every Area 1 pad WITH the build animation → Area 2 opens live →
       the lever + jar build in with the LEGO fly-in (reveal)
    4. camera on the lever: board (READY!) + the owner's hold prompt (E / X glyph) → desktop shot +
       device matrix (phone / tablet / console)
    5. REAL pull: the client holds the lever prompt (InputHoldBegin → HoldDuration → InputHoldEnd)
       → KineticAction "pull" (server fallback only if the hold could not be simulated); mid-pull
       shot (arm swung, nukes on the chute) + after shot (countdown board, the "MEGA PULL!"
       banner + "Every machine made bonus nukes: +$X")
    6. second pull while cooling down → refused (readyAt unchanged, cash unchanged)
    7. jar: admin fill → camera on the jar (full coin pile, FULL! board, prompt) → shot + matrix
    8. walk INTO the jar (real server Touched) → paid, jar empty → coin-burst shot
    9. Order Window seam: TipJar.addCoins → coin shower shot; collect it through the jar prompt
   10. reset (lever ready, switches on) and stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire lead
    STUDIO_LOCK_OWNER=lead python3 tools/qa/kinetic.py
    python3 scripts/studio-lock.py release lead
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

SERVER = (ROOT / "tools/qa/kinetic_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/kinetic_client.luau").read_text()
SERVER_COMMANDS = {"setup", "status", "to_lever", "to_jar", "near_jar", "fill_jar", "tip", "pull", "reset"}
CLIENT_COMMANDS = {"diag", "look_lever", "look_jar", "hold_lever", "hold_jar", "camera_reset", "close_all"}
OUT = ROOT / "docs/verification/r90-kinetic"
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def safe_json(raw: str) -> dict:
    """A probe answer as a dict ({"raw": text} when it is not JSON)."""
    try:
        value = json.loads(raw)
        return value if isinstance(value, dict) else {"raw": raw}
    except json.JSONDecodeError:
        return {"raw": raw}


def status() -> dict:
    return safe_json(server("status"))


def diag() -> dict:
    return safe_json(client("diag"))


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    try:
        world_tour.capture(path)
    except Exception as error:  # keep going: the record says what failed
        return f"capture failed: {error}"[:200]
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 0.8,
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


def wait_until(predicate, seconds: float, every: float = 1.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Exception:  # VM not up yet
            pass
        time.sleep(every)
    return None


def runtime_errors() -> list[str]:
    """Client / server log lines from the Kinetic modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
    keys = ("Kinetic", "MegaLever", "TipJar")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line][:40]


def wallet(record: dict) -> float:
    try:
        return float(record.get("cash", -1))
    except (TypeError, ValueError):
        return -1.0


def main() -> int:
    world_tour.require_lock()
    state = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    try:
        running = json.loads(state).get("running") is True
    except (json.JSONDecodeError, AttributeError):
        running = True  # unknown state: never start on top of someone else's playtest
    if running:
        raise SystemExit(f"a playtest is already running (not ours): {state[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_until(lambda: (lambda d: d if d.get("hud") else None)(diag()), 150)
        time.sleep(6)  # plot assignment + first profile push + boot windows
        client("close_all")
        # 3. Reveal: Area 2 opens live → both props build in.
        record["setup"] = safe_json(server("setup"))
        record["revealShot"] = None
        time.sleep(1.2)
        log("to_lever " + server("to_lever"))
        client("look_lever", [22])
        record["revealShot"] = shot("r90-reveal-flyin")
        placed = wait_until(lambda: (lambda s: s if (s.get("status") or {}).get("placed", {}).get(s.get("world", "main")) else None)(status()), 20, 1.0)
        record["placed"] = placed
        time.sleep(5)  # let the build-in settle
        # 4. Lever ready: board + prompt.
        client("look_lever", [18])
        time.sleep(0.6)
        record["leverDiag"] = diag()
        record["leverShot"] = shot("r90-lever-ready-desktop")
        record["leverDevices"] = matrix("r90-lever-ready")
        # 5. REAL pull through the hold prompt.
        before = status()
        record["holdLever"] = client("hold_lever")
        if record["holdLever"] != "held":
            record["pullFallback"] = safe_json(server("pull"))
        time.sleep(0.35)
        record["midPullDiag"] = diag()
        record["midPullShot"] = shot("r90-lever-mega-batch-mid")
        time.sleep(1.6)
        after = status()
        record["afterPullShot"] = shot("r90-lever-mega-batch-after")
        record["afterPullDiag"] = diag()
        record["pull"] = {"cashBefore": wallet(before), "cashAfter": wallet(after),
                          "readyAt": ((after.get("lever") or {}).get("ReadyAt")), "now": after.get("now")}
        # 6. Second pull while cooling down → refused.
        record["secondPull"] = safe_json(server("pull"))
        # 7. Jar: admin fill → full pile + board + prompt.
        record["fill"] = safe_json(server("fill_jar"))
        log("near_jar " + server("near_jar", [8]))
        client("look_jar", [12])
        time.sleep(1.2)
        record["jarDiag"] = diag()
        record["jarShot"] = shot("r90-jar-full-desktop")
        record["jarDevices"] = matrix("r90-jar-full")
        # 8. Walk INTO the jar (server Touched).
        jar_before = status()
        log("to_jar " + server("to_jar"))
        time.sleep(0.5)
        record["burstShot"] = shot("r90-jar-coin-burst")
        time.sleep(1.5)
        jar_after = status()
        record["touch"] = {"cashBefore": wallet(jar_before), "cashAfter": wallet(jar_after),
                           "jarAfter": (jar_after.get("status") or {}).get("jar")}
        # 9. Order Window seam: a tip drops in (coin shower), then the jar prompt collects it.
        log("near_jar " + server("near_jar", [7]))
        client("look_jar", [12])
        time.sleep(0.8)
        record["tip"] = safe_json(server("tip", [30]))
        time.sleep(0.25)
        record["tipShot"] = shot("r90-jar-tip-shower")
        time.sleep(1.2)
        tip_before = status()
        record["holdJar"] = client("hold_jar")
        time.sleep(1.2)
        tip_after = status()
        record["promptCollect"] = {"cashBefore": wallet(tip_before), "cashAfter": wallet(tip_after)}
        record["errors"] = runtime_errors()
        log("reset " + server("reset"))
        client("camera_reset")
    except Exception as error:  # keep the partial record: it is the diagnosis
        record["error"] = repr(error)[:500]
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])

    lever_diag = record.get("leverDiag") or {}
    jar_diag = record.get("jarDiag") or {}
    pull = record.get("pull") or {}
    touch = record.get("touch") or {}
    prompt_collect = record.get("promptCollect") or {}
    placed = record.get("placed") or {}
    checks = {
        "no error": "error" not in record,
        "props placed after the live unlock": bool(placed),
        "meshes (not the primitive fallback)": placed.get("leverMesh") == "Mesh" and placed.get("jarMesh") == "Mesh",
        "owner lever prompt on E / ButtonX, enabled": (lever_diag.get("leverPrompt") or {}).get("enabled") is True
        and (lever_diag.get("leverPrompt") or {}).get("key") == "E"
        and (lever_diag.get("leverPrompt") or {}).get("pad") == "ButtonX",
        "lever board says READY": "READY" in (lever_diag.get("leverBoard") or ""),
        "pull paid": pull.get("cashAfter", -1) > pull.get("cashBefore", 0),
        "cooldown set": isinstance(pull.get("readyAt"), (int, float)) and pull["readyAt"] > (pull.get("now") or 0),
        "arm swung / FX ran": (record.get("midPullDiag") or {}).get("armMoved") is True
        or ((record.get("midPullDiag") or {}).get("stats") or {}).get("fx", {}).get("steps", 0) > 0,
        "second pull refused (cooldown)": (record.get("secondPull") or {}).get("reason") == "cooldown",
        "jar filled + pile visible": (record.get("fill") or {}).get("ok") is True and jar_diag.get("coinVisible") is True,
        "jar prompt enabled": (jar_diag.get("jarPrompt") or {}).get("enabled") is True,
        "walk-in payout": touch.get("cashAfter", -1) > touch.get("cashBefore", 0),
        "tip accepted": (record.get("tip") or {}).get("accepted", 0) > 0,
        "prompt collect paid the tip": prompt_collect.get("cashAfter", -1) > prompt_collect.get("cashBefore", 0),
        "no Kinetic errors in the logs": not record.get("errors"),
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
