#!/usr/bin/env python3
"""
rejoin_check.py — Studio QA of the Welcome Back rows after a REAL rejoin (owner R57 spec §6.6 /
plan §4 W12 task 4; W12). Solo playtests only (owner order 2026-10-31: no multiplayer), holding
the Studio lock (owner R33 + the lock rule). NON-destructive: the test profile keeps its Nuke
Town and Dino Valley progress (the only admin command is WorldUnlock, a no-op when unlocked).

Steps (captures under docs/verification/world2/rejoin-*):
    1. session 1: Dino Valley unlocked (WorldUnlock), the money noted, home, a short wait for the
       leave save (Studio saves to its own DataStore when API access is on), stop
    2. ~75 s away (> TycoonConfig.Offline.MinSeconds = 60)
    3. session 2: Welcome Back must open with a Nuke Town row AND a Dino Valley (Bones) row;
       capture + device matrix (phone, tablet, console); the money gained is recorded per wallet
       (cash vs Bones: each from its own world, owner R60)

Usage:
    python3 scripts/studio-lock.py acquire W12
    STUDIO_LOCK_OWNER=W12 python3 tools/qa/rejoin_check.py
    python3 scripts/studio-lock.py release W12
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import world_tour  # noqa: E402  (require_lock, sheet, stop_playtest)
import world2_check as w2  # noqa: E402  (server / client / admin / matrix / wait_client helpers)

OUT = ROOT / "docs/verification/world2"
# Away time: longer than TycoonConfig.Offline.MinSeconds (60; shorter absences pay nothing and show
# no Welcome Back by design — the first run waited 30 s and correctly got no popup).
AWAY_SECONDS = 75


def main() -> int:
    world_tour.require_lock()
    w2.WORLD = "dino"
    w2.OUT = OUT
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"started": time.strftime("%Y-%m-%d %H:%M:%S")}
    names: list[str] = []
    try:
        # 1. Session 1.
        w2.start_solo()
        try:
            record["ready1"] = w2.wait_client(w2.ready, 150)
            time.sleep(4)
            w2.server("prepare")
            w2.client("modal_close")
            record["unlock"] = w2.admin(w2.UNLOCK)
            record["home"] = w2.admin(w2.SEND_HOME)
            record["moneyBefore"] = w2.money()
            time.sleep(8)  # leave + autosave stamps (lastSeenAt)
        finally:
            world_tour.stop_playtest()
        # 2. Away.
        time.sleep(AWAY_SECONDS)
        # 3. Session 2: Welcome Back rows.
        w2.start_solo()
        try:
            record["ready2"] = w2.wait_client(w2.ready, 150)
            record["welcome"] = w2.wait_client(lambda s: s.get("open", {}).get("WelcomeBack"), 25)
            record["welcomeOpen"] = bool(record["welcome"].get("open", {}).get("WelcomeBack"))
            if record["welcomeOpen"]:
                w2.shot("rejoin-welcome-back", names)
                w2.matrix("rejoin-welcome-back", names)
            w2.server("prepare")
            record["moneyAfter"] = w2.money()
            before, after = record["moneyBefore"], record["moneyAfter"]
            record["gained"] = {
                "cash": after["cash"] - before["cash"],
                "bones": after["worldCash"] - before["worldCash"],
                "tokens": after["tokens"] - before["tokens"],
                "gems": after["gems"] - before["gems"],
            }
            w2.client("modal_close")
        finally:
            world_tour.stop_playtest()
    finally:
        (OUT / "rejoin.json").write_text(json.dumps(record, indent=2) + "\n")
        if names:
            world_tour.sheet(OUT, names, OUT / "rejoin-sheet.jpg", cols=4, width=480)
    print(json.dumps({k: record.get(k) for k in ("welcomeOpen", "gained")}, indent=1))
    return 0 if record.get("welcomeOpen") else 1


if __name__ == "__main__":
    sys.exit(main())
