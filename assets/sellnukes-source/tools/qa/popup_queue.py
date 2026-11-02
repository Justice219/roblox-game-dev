#!/usr/bin/env python3
"""
popup_queue.py — Studio QA for the owner R102 popup priority queue + the R108 / R111 bottom-left
FEED (src/client/UI/Widgets/{PopupQueue, PopupQueueLogic, FeedLogic}, presenters UI/Hud/Toasts,
Tycoon/Fx/{BigPopBanner, JuiceBanner}, UI/Screens/FlavorReveal, LuckyArrow, HappyHourChip,
PlotReveal, YouMarker). One solo playtest in the open place (hold the Studio lock; never run while
someone else's playtest is going).

Steps (prints one JSON record + a verdict; captures under docs/verification/r102-popup-queue/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the HUD + profile, close the join windows
    3. R108 reveal + R102 LUCKY BUTTON: the (forced) first-find Galaxy card (held) plays bottom-left
       (no letterbox, no HUD fade), then the SERVER spawns a real Lucky Button (its toast fires
       during the reveal) -> probe: lane = flavorReveal, card in the bottom-left corner, nothing
       overlapping, arrow hidden -> desktop shot + device matrix -> release -> the toast shows
    4. R108 / R120 Big Pop: four other-player broadcasts -> ONE pill (one per 30 s, coalesced), and
       three Galaxy Lucky Nukes -> ONE merged "GALAXY x3" pill, no centre popup; bottom-left, clear
       of the left grid / objective chip / hint bar / currency stack -> desktop shot + device matrix
    5. R111 goals: three "Goal claimed! +10 Gems" -> one "x3 +30 Gems" pill; the long Lucky Nuke
       toast wraps in the feed -> desktop shot + device matrix
    6. R111 window: the Quests window open + a goal toast -> the pill sits in the gutter / under the
       window, never over it -> desktop shot + device matrix
    7. Priority: juice (6 s), Happy Hour (4 s) pre-empts it, juice resumes with its full hold, the
       lane ends free
    8. Chips: a juice banner with a live Lucky Button -> the arrow chip hides, the Happy pill
       reports "popup"
    9. YOU marker: enabled == not covering the currency stack
   10. stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire Q-queue
    STUDIO_LOCK_OWNER=Q-queue python3 tools/qa/popup_queue.py
    python3 scripts/studio-lock.py release Q-queue
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
import world_tour  # noqa: E402  (require_lock, render, result, capture)

CLIENT = (ROOT / "tools/qa/popup_queue_client.luau").read_text()
COMMANDS = {"diag", "closeall", "reveal", "release", "luckytoast", "flavortoast", "goals", "bigpop", "pills",
            "quests", "juice", "happy", "probe"}
OUT = ROOT / "docs/verification/r102-popup-queue"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]

# Server: spawn / clear a real Lucky Button for the only player (LuckyButtonService admin seam).
SERVER_LUCKY = """
local Server = game:GetService("ServerScriptService").Server
local LuckyButtonService = require(Server.Services.LuckyButtonService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
if "__MODE__" == "clear" then LuckyButtonService.clearAll() return "cleared" end
local ok, result = LuckyButtonService.spawnFor(player, "cash")
return tostring(ok) .. " " .. tostring(result)
"""


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def client_json(command: str, args: list[float] | None = None) -> dict:
    raw = client(command, args)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"raw": raw[:300]}


def server_lucky(mode: str) -> str:
    code = SERVER_LUCKY.replace('"__MODE__"', json.dumps("clear" if mode == "clear" else "spawn"))
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
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


def runtime_errors() -> list[str]:
    """Client / server log lines from the queue + presenters that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
    keys = ("PopupQueue", "Toasts", "BigPopBanner", "JuiceBanner", "FlavorReveal", "FlavorController",
            "LuckyArrow", "HappyHourChip", "PlotReveal", "YouMarker")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line][:40]


def verdict(record: dict) -> dict:
    """The pass / fail summary of the probes (the lead reads this first)."""
    checks: dict[str, bool] = {}
    reveal = record.get("revealProbe", {})
    checks["reveal holds the lane"] = reveal.get("queue", {}).get("active") == "flavorReveal"
    checks["R108 reveal card bottom-left"] = reveal.get("cardInCorner") is True
    checks["R108 no HUD fade during the reveal"] = reveal.get("focus") is False
    checks["nothing overlaps during the reveal"] = not reveal.get("overlaps")
    checks["arrow hidden during reveal"] = reveal.get("arrowVisible") is False
    after = record.get("afterReveal", {})
    checks["lucky toast shows after the reveal"] = after.get("toasts", {}).get("shown", 0) >= 1
    checks["nothing overlaps after the reveal"] = not after.get("overlaps")
    big = record.get("bigPopProbe", {})
    checks["R120 one Big Pop pill per 30 s"] = big.get("toasts", {}).get("bigPops") == 1
    checks["R108 pills clear of grid / objective / hints / stack"] = not big.get("overlaps") \
        and len(big.get("toastRects", [])) >= 1
    pills = record.get("pills", {})
    pill_texts = pills.get("toasts", {}).get("texts", [])
    checks["R120 Lucky Nuke pills merge (GALAXY x3)"] = any("GALAXY x3" in t for t in pill_texts)
    checks["R120 no centre Lucky Nuke popup"] = pills.get("juice") is False
    goals = record.get("goalsProbe", {})
    texts = goals.get("toasts", {}).get("texts", [])
    checks["R111 goal toasts merge (x3 +30 Gems)"] = any("x3 +30 Gems" in t for t in texts)
    checks["R111 feed clear of the HUD"] = not goals.get("overlaps")
    window = record.get("windowProbe", {})
    checks["R111 Quests window measured"] = window.get("hud", {}).get("window") is not None
    checks["R111 no pill over the window"] = not window.get("overlaps")
    prio = record.get("priority", {})
    checks["happy hour pre-empts juice"] = prio.get("preempt", {}).get("active") == "happyHour" \
        and "juice" in prio.get("preempt", {}).get("waiting", [])
    checks["juice resumes after"] = prio.get("resumed", {}).get("active") == "juice"
    checks["lane free at the end"] = prio.get("end", {}).get("active") is None
    chips = record.get("chips", {})
    checks["arrow hides under a banner"] = chips.get("during", {}).get("arrowVisible") is False
    # The pill only has to yield when it was showing before the banner (else it is hidden anyway).
    pill_before = chips.get("before", {}).get("pillHidden")
    checks["happy pill yields to a banner"] = pill_before != "" or chips.get("during", {}).get("pillHidden") == "popup"
    you = record.get("you", {}).get("you") or {}
    checks["YOU marker hidden only over the stack"] = you == {} or you.get("covered") is None \
        or you.get("enabled") == (not you.get("covered"))
    checks["no queue / presenter errors"] = not record.get("logIssues")
    return {"passed": all(checks.values()), "checks": checks}


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
        time.sleep(8)  # plot reveal fly-over + first profile push
        log("closeall " + client("closeall"))
        time.sleep(1.0)

        # 3. Reveal + the real LUCKY BUTTON toast.
        record["reveal"] = client_json("reveal")
        log("lucky " + server_lucky("spawn"))
        time.sleep(1.2)
        record["revealProbe"] = client_json("probe")
        record["revealShot"] = shot("r108-reveal-card-lucky-desktop")
        record["revealDevices"] = matrix("r108-reveal-card-lucky")
        record["released"] = client_json("release")
        time.sleep(0.8)
        record["afterReveal"] = client_json("probe")
        record["afterRevealShot"] = shot("r102-after-reveal-desktop")
        log("lucky clear " + server_lucky("clear"))
        time.sleep(4.0)  # toasts finish

        # 4. R108 / R120 Big Pop pills: four other-player broadcasts → ONE pill (the rest wait 30 s)
        #    + three Galaxy Lucky Nukes → ONE merged pill, nothing centre-screen.
        record["bigPop"] = client_json("bigpop")
        record["pills"] = client_json("pills")
        record["bigPopProbe"] = client_json("probe")
        record["bigPopShot"] = shot("r108-bigpop-pills-desktop")
        record["bigPopDevices"] = matrix("r108-bigpop-pills")

        # 5. R111 goals merge + the long toast wrapping in the feed (pills still up).
        record["goals"] = client_json("goals")
        log("flavortoast " + client("flavortoast"))
        record["goalsProbe"] = client_json("probe")
        record["goalsShot"] = shot("r111-goals-merged-desktop")
        record["goalsDevices"] = matrix("r111-goals-merged")

        # 6. R111 window: the Quests window + a goal toast.
        record["quests"] = client_json("quests")
        time.sleep(0.8)
        record["windowProbe"] = client_json("probe")
        record["windowShot"] = shot("r111-toast-beside-window-desktop")
        record["windowDevices"] = matrix("r111-toast-beside-window")
        log("closeall " + client("closeall"))
        # Let every pill / banner run out (bounded poll; nothing may be on screen for step 7).
        for _ in range(25):
            diag = client_json("diag")
            if diag.get("queue", {}).get("active") is None:
                break
            time.sleep(2)
        time.sleep(4)

        # 7. Priority: juice 6 s; Happy Hour 4 s cuts in (juice waits, then resumes with its full
        #    hold); then the lane is free.
        prio: dict = {}
        prio["juice"] = client_json("juice", [6])
        time.sleep(0.6)
        prio["happy"] = client_json("happy", [4])
        prio["preempt"] = client_json("diag").get("queue", {})
        time.sleep(4.5)
        prio["resumed"] = client_json("diag").get("queue", {})
        time.sleep(7.0)
        prio["end"] = client_json("diag").get("queue", {})
        record["priority"] = prio

        # 7. Chips under a banner (a live Lucky Button).
        chips: dict = {}
        log("lucky " + server_lucky("spawn"))
        time.sleep(4.0)  # its toast + the arrow appear
        chips["before"] = client_json("probe")
        chips["juice"] = client_json("juice", [8])
        chips["during"] = client_json("probe")
        chips["duringShot"] = shot("r102-chips-under-banner-desktop")
        time.sleep(8.5)
        chips["after"] = client_json("probe")
        log("lucky clear " + server_lucky("clear"))
        record["chips"] = chips

        # 8. YOU marker.
        record["you"] = client_json("probe")
        record["logIssues"] = runtime_errors()
        record["verdict"] = verdict(record)
    finally:
        world_tour.stop_playtest()
    print(json.dumps(record, indent=1))
    return 0 if record.get("verdict", {}).get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
