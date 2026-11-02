#!/usr/bin/env python3
"""
worlds_ui.py — Studio check of the worlds UI (owner R57 World 2 "Dino Valley", W5 worlds-ui;
plan §4 W5 task 6). One solo playtest in the open place; hold the Studio lock (owner R33 + the
lock rule) and never run it while someone else's playtest is up.

Reuses W12's server half (tools/qa/world2_check.luau: snapshot / admin pipeline / restore) and
adds a W5 client probe (tools/qa/worlds_ui_client.luau). Everything goes through the real game
code: admin commands via AdminService.dispatchAsync, travel via WorldClient.travel (the real
TravelWorld intent), screens via the real ScreenManager.

Steps (JSON record + captures under docs/verification/world2/ui/; device matrix = phone /
tablet / console via capture_device_matrix):
    1. ready + snapshot the Dino save; relock Dino (admin)
    2. Teleport on the LOCKED Dino tab (matrix) + the locked-preview popup (matrix)
    3. admin unlock -> the WORLD UNLOCKED popup opens by itself at a polite moment (matrix);
       the HUD Teleport NEW tag is on (matrix)
    4. rejoin chip (matrix), Welcome Back with per-world rows (matrix)
    5. travel to Base Camp (real intent): warp overlay capture, then the Valley HUD (Bones primary,
       Cash pill, Attack hidden, Time Traveler offer, objective chip; matrix), lighting preset,
       music "dino", jungle bed playing
    6. in the Valley: Teleport (Dino tab), Rebirth (Dino tab + Amber shop + link lines with 3 Dino
       rebirths), Shop (DINO VALLEY section) — each with a matrix
    7. back to Nuke Town (real intent): lighting restored, bed stopped, music automatic
    8. restore the Dino save snapshot, stop OUR playtest
    `--mode recheck` runs the short re-verification instead: unlock popup (with a trace of the
    polite-moment gate), rejoin chip, the Valley HUD hint bar (no Attack), the Valley Shop.
    `--mode hud` (owner R59 phone HUD): the bare HUD in Nuke Town and in Dino Valley, desktop +
    phone / tablet / console matrices, with the published HUD zones per capture.
    `--mode owner` (owner R59-R62 in one pass): HUD + Teleport balances in both worlds (matrices),
    the R61 repro on the own Dino plot (real UPGRADE press: raw vs projected burst origin + an
    instant capture; a real PadBuy; travel both ways) with CurrencyFly burst counts around each.

Usage:
    python3 scripts/studio-lock.py acquire W5b-ui
    STUDIO_LOCK_OWNER=W5b-ui python3 tools/qa/worlds_ui.py [--mode full|recheck]
    python3 scripts/studio-lock.py release W5b-ui
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

os.environ.setdefault("STUDIO_LOCK_OWNER", "W5b-ui")

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world2_check as w2  # noqa: E402  (server half: prepare / admin / restore; matrix)
import world_tour  # noqa: E402  (require_lock, render, result, capture, stop_playtest)

CLIENT = (ROOT / "tools/qa/worlds_ui_client.luau").read_text()
CLIENT_COMMANDS = {"state", "modal_close", "open", "travel", "upgrade", "padbuy", "flystate"}
OUT = ROOT / "docs/verification/world2/ui"
# Screen codes of worlds_ui_client.luau `open`.
TELEPORT, TELEPORT_DINO, REBIRTH, SHOP, WELCOME, REJOIN, LOCKED_PREVIEW, UNLOCKED, REBIRTH_DINO = range(1, 10)


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def state() -> dict:
    return json.loads(client("state"))


def wait_state(predicate, seconds: float, step: float = 1.0) -> dict:
    """Polls state() until predicate(state) or the deadline; returns the last state."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = state()
            if predicate(last):
                return last
        except Exception as error:  # client VM not up yet / streaming
            last = {"error": str(error)[:200]}
        time.sleep(step)
    return last


def shot(name: str, names: list[str]) -> None:
    world_tour.capture(OUT / f"{name}.jpg")
    names.append(f"{name}.jpg")
    print(f"[ui] {name}.jpg", flush=True)


def matrix(name: str, names: list[str]) -> None:
    w2.matrix(name, names)
    print(f"[ui] {name} matrix", flush=True)


def screen(record: dict, names: list[str], key: str, code: int, settle: float = 1.4) -> None:
    """Opens one screen, records the probe, captures desktop + the device matrix, closes it."""
    client("modal_close")
    time.sleep(0.6)
    record[key + "Open"] = client("open", [code])
    time.sleep(settle)
    record[key] = state()
    shot(key, names)
    matrix(key, names)
    client("modal_close")
    time.sleep(0.6)


def unlock_popup(record: dict, names: list[str], prefix: str) -> None:
    """Relock + unlock (admin); traces the WORLD UNLOCKED gate until the popup opens (<= 30 s)."""
    record["relock"] = w2.admin(w2.RELOCK)
    time.sleep(1.5)
    client("modal_close")
    record["unlock"] = w2.admin(w2.UNLOCK)
    trace: list = []
    deadline = time.time() + 30
    opened: dict = {}
    while time.time() < deadline:
        current = state()
        trace.append({"t": round(30 - (deadline - time.time()), 1), "open": current.get("open", {}).get("WorldUnlocked"),
                      "modal": current.get("modal"), "popup": current.get("popup")})
        if current.get("open", {}).get("WorldUnlocked"):
            opened = current
            break
        time.sleep(1.5)
    record["popupTrace"] = trace
    record["popup"] = opened
    time.sleep(1.2)
    shot(f"{prefix}-unlock-popup", names)
    matrix(f"{prefix}-unlock-popup", names)
    client("modal_close")
    time.sleep(1)


def recheck(record: dict, names: list[str]) -> None:
    record["ready"] = wait_state(lambda s: s.get("loadingDone") and s.get("plotIndex", 0) > 0 and s.get("revealed"), 150, 2)
    time.sleep(4)
    record["prepare"] = json.loads(w2.server("prepare"))
    client("modal_close")
    record["send home"] = w2.admin(w2.SEND_HOME)
    time.sleep(2)
    unlock_popup(record, names, "r1")
    screen(record, names, "r2-rejoin-chip", REJOIN, 1.6)
    record["travelOut"] = client("travel", [1])
    record["arrive"] = wait_state(lambda s: s.get("currentWorld") == "dino" and not s.get("open", {}).get("WorldTravel"), 25)
    time.sleep(3)
    client("modal_close")
    time.sleep(1)
    record["valley"] = state()
    shot("r3-hud-valley", names)
    matrix("r3-hud-valley", names)
    screen(record, names, "r4-shop-dino", SHOP, 2.4)
    record["travelHome"] = client("travel", [2])
    record["home"] = wait_state(lambda s: s.get("currentWorld") == "main" and not s.get("open", {}).get("WorldTravel"), 25)
    time.sleep(2)
    record["homeState"] = state()


def hud(record: dict, names: list[str]) -> None:
    record["ready"] = wait_state(lambda s: s.get("loadingDone") and s.get("plotIndex", 0) > 0 and s.get("revealed"), 150, 2)
    time.sleep(4)
    record["prepare"] = json.loads(w2.server("prepare"))
    client("modal_close")
    record["send home"] = w2.admin(w2.SEND_HOME)
    time.sleep(3)
    client("modal_close")
    time.sleep(1)
    record["main"] = state()
    shot("r59-hud-main", names)
    matrix("r59-hud-main", names)
    record["travelOut"] = client("travel", [1])
    record["arrive"] = wait_state(lambda s: s.get("currentWorld") == "dino" and not s.get("open", {}).get("WorldTravel"), 25)
    time.sleep(3)
    client("modal_close")
    time.sleep(1)
    record["dino"] = state()
    shot("r59-hud-dino", names)
    matrix("r59-hud-dino", names)
    record["travelHome"] = client("travel", [2])
    record["home"] = wait_state(lambda s: s.get("currentWorld") == "main" and not s.get("open", {}).get("WorldTravel"), 25)


def fly() -> dict:
    return json.loads(client("flystate"))


def owner(record: dict, names: list[str]) -> None:
    record["ready"] = wait_state(lambda s: s.get("loadingDone") and s.get("plotIndex", 0) > 0 and s.get("revealed"), 150, 2)
    time.sleep(4)
    record["prepare"] = json.loads(w2.server("prepare"))
    client("modal_close")
    record["send home"] = w2.admin(w2.SEND_HOME)
    time.sleep(3)
    client("modal_close")
    time.sleep(1)
    record["main"] = state()
    shot("f1-hud-main", names)
    matrix("f1-hud-main", names)
    screen(record, names, "f2-teleport-main", TELEPORT, 1.6)
    record["fly0"] = fly()
    record["travelOut"] = client("travel", [1])
    record["arrive"] = wait_state(lambda s: s.get("currentWorld") == "dino" and not s.get("open", {}).get("WorldTravel"), 25)
    time.sleep(3)
    client("modal_close")
    record["fly1"] = fly()
    record["dino"] = state()
    shot("f3-hud-dino", names)
    matrix("f3-hud-dino", names)
    # R61 repro on the own Dino plot.
    record["sendPlot"] = w2.admin(w2.SEND_PLOT)
    time.sleep(6)
    client("modal_close")
    record["fly2"] = fly()
    record["upgrade"] = client("upgrade")
    time.sleep(0.25)
    shot("f4-upgrade-burst", names)
    time.sleep(2.5)
    record["fly3"] = fly()
    record["padbuy"] = client("padbuy")
    time.sleep(3)
    record["fly4"] = fly()
    shot("f5-after-padbuy", names)
    screen(record, names, "f6-teleport-dino", TELEPORT, 1.6)
    record["travelHome"] = client("travel", [2])
    record["home"] = wait_state(lambda s: s.get("currentWorld") == "main" and not s.get("open", {}).get("WorldTravel"), 25)
    time.sleep(2)
    record["fly5"] = fly()
    record["homeState"] = state()
    shot("f7-home", names)


def run(record: dict, names: list[str]) -> None:
    record["ready"] = wait_state(lambda s: s.get("loadingDone") and s.get("plotIndex", 0) > 0 and s.get("revealed"), 150, 2)
    time.sleep(4)
    record["prepare"] = json.loads(w2.server("prepare"))
    client("modal_close")
    # 1-2. Locked: Teleport's locked tab + the locked preview.
    record["relock"] = w2.admin(w2.RELOCK)
    record["send home"] = w2.admin(w2.SEND_HOME)
    time.sleep(2)
    screen(record, names, "01-teleport-locked-tab", TELEPORT_DINO)
    screen(record, names, "02-locked-preview", LOCKED_PREVIEW)
    # 3. Unlock -> the popup opens by itself at a polite moment.
    record["unlock"] = w2.admin(w2.UNLOCK)
    record["popup"] = wait_state(lambda s: s.get("open", {}).get("WorldUnlocked"), 25)
    time.sleep(1.2)
    shot("03-unlock-popup", names)
    matrix("03-unlock-popup", names)
    client("modal_close")
    time.sleep(1.5)
    record["hudMainNew"] = state()
    shot("04-hud-main-new-tag", names)
    matrix("04-hud-main-new-tag", names)
    # 4. Rejoin chip + Welcome Back rows.
    screen(record, names, "05-rejoin-chip", REJOIN, 1.6)
    screen(record, names, "06-welcome-back-rows", WELCOME, 2.4)
    # 5. Travel (real intent) -> overlay -> the Valley HUD.
    record["travelOut"] = client("travel", [1])
    time.sleep(0.5)
    shot("07-warp-overlay", names)
    record["warp"] = state()
    record["arrive"] = wait_state(lambda s: s.get("currentWorld") == "dino" and not s.get("open", {}).get("WorldTravel"), 25)
    time.sleep(3)
    client("modal_close")
    time.sleep(1)
    record["valley"] = state()
    shot("08-hud-valley", names)
    matrix("08-hud-valley", names)
    # 6. Valley screens (3 Dino rebirths so the link lines show real numbers).
    record["rebirths"] = w2.admin(w2.SET_REBIRTHS, 3)
    time.sleep(1)
    screen(record, names, "09-teleport-dino", TELEPORT)
    screen(record, names, "10-rebirth-dino", REBIRTH, 1.8)
    screen(record, names, "11-shop-dino", SHOP, 2.4)
    # 7. Home (real intent): lighting restored, bed stopped, music automatic.
    record["travelHome"] = client("travel", [2])
    record["home"] = wait_state(lambda s: s.get("currentWorld") == "main" and not s.get("open", {}).get("WorldTravel"), 25)
    time.sleep(2)
    client("modal_close")
    record["homeState"] = state()
    shot("12-home", names)


def main() -> int:
    parser = argparse.ArgumentParser(description="W5 worlds UI Studio check")
    parser.add_argument("--mode", choices=["full", "recheck", "hud", "owner"], default="full")
    mode = parser.parse_args().mode
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    w2.OUT = OUT  # W12's matrix helper writes into our folder
    record: dict = {}
    names: list[str] = []
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    if json.loads(status).get("running"):
        print(json.dumps({"aborted": "a playtest is already running", "status": status[:200]}))
        return 2
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:160], flush=True)
    try:
        {"recheck": recheck, "hud": hud, "owner": owner}.get(mode, run)(record, names)
    except Exception as error:  # report, then always restore + stop our playtest
        record["error"] = str(error)[:600]
    finally:
        try:
            record["restore"] = w2.server("restore")
        except Exception as error:
            record["restoreError"] = str(error)[:300]
        world_tour.stop_playtest()
    record["captures"] = names
    (OUT / f"worlds_ui{'' if mode == 'full' else '_' + mode}.json").write_text(json.dumps(record, indent=1))
    print(json.dumps(record)[:6000])
    return 0 if "error" not in record else 1


if __name__ == "__main__":
    sys.exit(main())
