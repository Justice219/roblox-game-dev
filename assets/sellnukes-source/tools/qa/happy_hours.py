#!/usr/bin/env python3
"""
happy_hours.py — Studio QA for R89 Nukey's Happy Hours (E-events): the HUD chip, the schedule
panel, the start banner, Confetti Storm pickups (real walk-in claims), Double Pops' eventCash, the
world events away from their world, the kill switch and the admin force / stop / skip seams.
One SOLO playtest in the open place (owner R72: never multiplayer; hold the Studio lock).

Steps (prints one JSON record + a check list; captures under docs/verification/r89-events/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running; start a solo Play
       playtest, wait for the HUD + profile, close the boot windows
    2. NEXT chip (whatever the schedule says; a live event is stopped first) -> per-device diag
       + device matrix r89-events-chip-next-*
    3. Force CONFETTI STORM (admin seam) -> banner + LIVE chip -> matrix r89-events-banner-*;
       pickups fall (near the player) -> desktop shot r89-events-confetti-desktop;
       walk into the nearest coin (own character) -> claimed counter + wallet
    4. Schedule panel (the chip's tap) -> chip hidden while it is open -> per-device diag + matrix
       r89-events-schedule-*; gamepad selection on the chip
    5. Force DOUBLE POPS -> server eventCash 1.25 + client bonus pops on; Force LOW-GRAVITY and EGG
       STAMPEDE away from their worlds -> "· Moon Base" / "· Dino Valley" chip + GO rows ->
       matrix r89-events-away-*; if Moon Base is already unlocked on this profile: travel there,
       event gravity + floating moon rocks shot r89-events-moon-desktop
    6. Skip + kill switch: chip hidden, luck 1; revive; stop -> back to the schedule
    7. stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire E-events
    STUDIO_LOCK_OWNER=E-events python3 tools/qa/happy_hours.py
    python3 scripts/studio-lock.py release E-events
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
import world_tour  # noqa: E402  (require_lock, render, result, capture, stop_playtest)

SERVER = (ROOT / "tools/qa/happy_hours_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/happy_hours_client.luau").read_text()
SERVER_COMMANDS = {"status", "force", "stop", "skip", "kill", "revive", "spawn", "pickups", "send", "home"}
CLIENT_COMMANDS = {"diag", "close_all", "open_schedule", "close_schedule", "select_chip", "deselect", "goto",
                   "hud_off", "hud_on"}
OUT = ROOT / "docs/verification/r89-events"
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
# HappyHourConfig.EventIds order (1-based for the Luau side).
CONFETTI, SPRINKLE, POPS, STAMPEDE, LOWGRAV = 1, 2, 3, 4, 5


def safe_json(raw: str) -> dict:
    try:
        value = json.loads(raw)
        return value if isinstance(value, dict) else {"raw": raw}
    except json.JSONDecodeError:
        return {"raw": raw}


def server(command: str, args: list[float] | None = None) -> dict:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return safe_json(world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code})))


def client(command: str, args: list[float] | None = None) -> dict:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return safe_json(world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code})))


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client, ONE device per call (a slow console emulation
    times out a three-device call); one jpg per device, failures noted and skipped."""
    names = []
    for device in DEVICES:
        try:
            client("close_all")  # a join-flow prompt must not cover the capture
            response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
                "entries": [device], "target": "client-1", "format": "jpeg", "quality": 88,
                "settleSeconds": 1.5, "restoreAfter": True,
            }})
            images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
            if not images:
                names.append(f"{device['label']} failed: " + json.dumps(response)[:200])
                continue
            path = OUT / f"{prefix}-{device['label']}.jpg"
            path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
            names.append(str(path.relative_to(ROOT)))
        except Exception as error:  # keep going: the other devices still get captured
            names.append(f"{device['label']} failed: {str(error)[:200]}")
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
            if command == "diag":
                client("close_all")  # stray join-flow prompts (NotifyPrompt) would hide the chip
                time.sleep(0.5)
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


def runtime_errors() -> list[str]:
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 500})
    keys = ("HappyHour", "WorldGravity", "LuckyButtonService")
    # Studio without API services: the cross-server store / topic warn once and fall back to this
    # server (expected there; reported under "environment", not as failures).
    environment = ("subscribe failed", "publish failed", "DataStore unavailable")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines
            if ("rror" in line or "arn" in line) and not any(e in line for e in environment)][:40]


def main() -> int:
    world_tour.require_lock()
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    try:
        running = json.loads(status).get("running") is True
    except (json.JSONDecodeError, AttributeError):
        running = True  # unknown state: never start on top of someone else's playtest
    if running:
        raise SystemExit(f"a playtest is already running or Studio is unreachable (not ours): {status[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_until(lambda: (lambda d: d if d.get("hud") and d.get("profile") else None)(client("diag")), 150)
        time.sleep(8)  # first profile push + join queue (loading, plot reveal, tutorial card)
        client("close_all")
        time.sleep(1.0)
        record["start"] = server("status")
        # Boot: the chip must come up by itself once the join flow is out of the way.
        reasons = []
        for _ in range(12):
            d = client("diag")
            reasons.append(d.get("hiddenReason"))
            if d.get("chipVisible"):
                break
            client("close_all")
            time.sleep(1.5)
        record["bootReasons"] = reasons
        # 2. NEXT chip.
        if (record["start"].get("live") or {}).get("id"):
            log("stop natural " + json.dumps(server("stop"))[:200])
            time.sleep(1.5)
        record["next"] = per_device("diag")
        record["nextShots"] = matrix("r89-events-chip-next")
        record["nextDesktop"] = shot("r89-events-chip-next-desktop")
        # 3. Confetti Storm.
        record["forceConfetti"] = server("force", [CONFETTI, 240])
        time.sleep(1.2)
        record["banner"] = client("diag")
        record["bannerShots"] = matrix("r89-events-banner")
        time.sleep(5)
        record["confettiServer"] = server("pickups")
        record["confetti"] = client("diag")
        record["confettiDesktop"] = shot("r89-events-confetti-desktop")
        before = server("status")
        record["claim"] = client("goto", [0])
        time.sleep(1.5)
        after = server("status")
        record["wallet"] = {"before": [before.get("cash"), before.get("gems")], "after": [after.get("cash"), after.get("gems")],
                            "pickups": after.get("pickups")}
        record["claimDesktop"] = shot("r89-events-claim-desktop")
        # 4. Schedule panel + gamepad selection.
        record["schedule"] = per_device("open_schedule")
        record["scheduleShots"] = matrix("r89-events-schedule")
        record["scheduleDesktop"] = shot("r89-events-schedule-desktop")
        record["closed"] = client("close_schedule")
        record["select"] = client("select_chip")
        client("deselect")
        # 5. Double Pops + world events away from their worlds.
        record["forcePops"] = server("force", [POPS, 120])
        time.sleep(2.0)
        client("close_all")
        record["pops"] = client("diag")
        record["forceMoon"] = server("force", [LOWGRAV, 180])
        time.sleep(2.0)
        client("close_all")
        record["moonAway"] = client("diag")
        record["awayShots"] = matrix("r89-events-away")
        record["awaySchedule"] = client("open_schedule")
        record["awayScheduleDesktop"] = shot("r89-events-away-schedule-desktop")
        client("close_schedule")
        record["send"] = server("send", [LOWGRAV])
        if record["send"].get("ok"):
            time.sleep(8)
            client("close_all")
            record["moon"] = client("diag")
            record["moonServer"] = server("pickups")
            record["moonDesktop"] = shot("r89-events-moon-desktop")
            server("home")
            time.sleep(6)
        record["forceStampede"] = server("force", [STAMPEDE, 120])
        time.sleep(2.0)
        client("close_all")
        record["stampedeAway"] = client("diag")
        # 6. Skip + kill switch + revive + stop.
        record["stop"] = server("stop")
        record["skip"] = server("skip")
        record["kill"] = server("kill")
        time.sleep(1.5)
        client("close_all")
        record["killed"] = client("diag")
        record["revive"] = server("revive")
        time.sleep(1.5)
        client("close_all")
        record["revived"] = client("diag")
        record["logIssues"] = runtime_errors()
    except Exception as error:  # keep the partial record: it is the diagnosis
        record["error"] = repr(error)[:500]
    finally:
        try:
            server("revive")
            server("stop")
        except Exception as error:
            record["cleanupError"] = repr(error)[:300]
        world_tour.stop_playtest()

    def every(group: dict | None, test) -> bool:
        return bool(group) and all(test(v) for v in group.values() if isinstance(v, dict))

    def clear(d: dict) -> bool:
        return d.get("chipVisible") and not d.get("hits") and not d.get("topbarHit")

    nxt = record.get("next") or {}
    sched = record.get("schedule") or {}
    claim = record.get("claim") or {}
    wallet = record.get("wallet") or {}
    stats = lambda key: ((record.get(key) or {}).get("stats") or {})
    checks = {
        "no error": "error" not in record,
        "chip shows after boot": (record.get("bootReasons") or ["?"])[-1] == "",
        # R92 pill: NEXT on desktop / tablet / console; phones show the LIVE state only.
        "NEXT pill on tablet / console, hidden on phone": every(nxt, lambda d: (d.get("hiddenReason") == "content")
                                                                if d.get("phone") else
                                                                (d.get("chipVisible") and " IN " in (d.get("title") or "")
                                                                 or " AT " in (d.get("title") or ""))),
        "pill clear of HUD zones / badge / admin / top bar": every(nxt, lambda d: d.get("phone") or clear(d)),
        "pill compact (<= 60 px tall off phone)": every(nxt, lambda d: d.get("phone") or (d.get("chipPt") or {}).get("h", 99) <= 60),
        "force confetti is live": (record.get("forceConfetti") or {}).get("ok") is True,
        "LIVE chip + banner": (record.get("banner") or {}).get("banner") is True
        and ((record.get("banner") or {}).get("title") or "").startswith("LIVE: CONFETTI"),
        "client agrees with the server": stats("confetti").get("live") == "confetti"
        and stats("confetti").get("serverLive") == "confetti",
        "confetti pickups spawned": len((record.get("confettiServer") or {}).get("list") or []) >= 1,
        "coins land near the player": ((record.get("confettiServer") or {}).get("nearest") or 999) <= 50,
        "storm sky on": (stats("confetti").get("fx") or {}).get("storm") is True,
        "walk-in claim paid": (claim.get("after") or {}).get("claimed", 0) > (claim.get("before") or {}).get("claimed", 0)
        and ((wallet.get("pickups") or {}).get("collected") or 0) >= 1,
        "schedule opens with rows": every(sched, lambda d: d.get("scheduleOpen") and len(d.get("rows") or []) >= 4),
        "chip hidden while a modal is open": every(sched, lambda d: not d.get("chipVisible")),
        "schedule text >= 14 pt": every(sched, lambda d: all(min(r.get("nameH") or 0, r.get("blurbH") or 0, r.get("timeH") or 0) >= 14
                                                           for r in d.get("rows") or [])),
        "pill text >= 14 pt": every(nxt, lambda d: d.get("phone") or (d.get("titlePt") or 0) >= 14),
        "chip back after closing": (record.get("closed") or {}).get("chipVisible") is True,
        "gamepad can select the chip": (record.get("select") or {}).get("selected") == "HappyHourChip",
        "double pops eventCash 1.25": ((record.get("forcePops") or {}).get("status") or {}).get("eventCash") == 1.25,
        "double pops bonus pops on": (stats("pops").get("fx") or {}).get("doublePops") == 1.25,
        "moon event pill LIVE": ((record.get("moonAway") or {}).get("title") or "").startswith("LIVE: LOW GRAVITY"),
        "away gravity untouched": ((stats("moonAway").get("gravity") or {}).get("scale") == 1),
        "GO row for the away event": any(r.get("go") for r in (record.get("awaySchedule") or {}).get("rows") or []),
        "stampede pill LIVE": ((record.get("stampedeAway") or {}).get("title") or "").startswith("LIVE: STAMPEDE"),
        "kill switch hides the chip": not (record.get("killed") or {}).get("chipVisible", True)
        and stats("killed").get("luck") == 1,
        "revive shows it again": (record.get("revived") or {}).get("chipVisible") is True,
        "no Happy Hour errors in the log": not record.get("logIssues"),
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1, default=str))
    failed = [name for name, ok in checks.items() if not ok]
    print("FAILED: " + ", ".join(failed) if failed else "ALL CHECKS PASSED")
    (OUT / "r89-events-record.json").write_text(json.dumps(record, indent=1, default=str))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
