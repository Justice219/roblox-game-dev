#!/usr/bin/env python3
"""
world2_check.py — the World 2 QA tour (owner R57 "Dino Valley", W12; plan §4 W12 tasks 4–7).
Drives the open place ("Sell Nukes") through the Studio MCP on localhost (scripts/studio_mcp.py);
hold the Studio lock and never run it while someone else's playtest is up (owner R33 + the lock
rule). Everything goes through the REAL game code: admin commands via AdminService.dispatchAsync
(the owner-admin pipeline), travel / rebirth via the real client intents, portals via the real
touch volume.

Modes (captures + JSON under docs/verification/world2/ for Dino Valley, docs/verification/<world>/ for
any other world, e.g. docs/verification/moon/):
    tour   solo playtest:
             admin relock + unlock -> WORLD UNLOCKED popup (+ device matrix) -> FRESH Dino run
             (WorldResetRun + Bones grant) -> R60 money note at home -> lobby Time Machine shot +
             swirl spin -> travel intent ("GO NOW") -> Base Camp (+ matrix) -> Valley return portal
             shot + swirl spin -> no attack UI in Dino -> Teleport tabs (+ matrix) -> buy the next
             Dino pad (build-in mid-flight + done shots) -> back home by the portal -> R60 money
             check (cash moved only by Nuke Town income) -> D6 finale pad label from the path ->
             WorldUnlockAll -> plot aerial + finale -> Dino rebirth intent -> return portal ->
             WorldOfflinePreview (Welcome Back rows) -> analytics keys recorded -> restore
    rejoin solo playtest x2: unlock + area 3 + home, stop, wait, start again -> Welcome Back rows
             (+ matrix) -> WorldWipe + WorldRelock (back to a fresh Dino state)
    npm    owner R67, solo playtest: real Dino progress noted -> admin panel header PLAY AS NEW
             PLAYER captured (+ device matrix) -> the panel's own send (AdminClient.send
             "NewPlayerMode": Studio's simulate_mouse_input never reaches Roblox GUI buttons) ->
             FAILS LOUDLY unless the NewPlayerMode attribute turns on -> sandbox checks (plot rebuilt
             from scratch, tutorial, first producer idle without a click, Dino locked, no worlds
             data) + the top-right NEW PLAYER MODE chip (+ device matrix) -> sandbox cash + 7 gems
             -> exit (fails loudly unless the attribute turns off) -> the real profile is back
             unchanged (Dino too) and the 7 sandbox gems were not saved
    popup  WORLD UNLOCKED reliability: --trials fresh sessions each of a NATURAL unlock (New Player
             Mode sandbox + real free pad purchases to Nuke Town area 3) and an ADMIN unlock
             (WorldRelock + WorldUnlock), plus one same-session relock -> unlock repeat
    No multiplayer mode: OWNER ORDER 2026-10-31 "stop running multiplayer playtests".
    perf   solo playtest: 8 full plots per world (TestBots for Nuke Town, full pad sets on the free
             Valley plots) -> server heartbeat / fps / instance count / memory per world, client
             frame ms in the Valley with the phone preset (Low FX tier), memory breakdown

Usage:
    python3 scripts/studio-lock.py acquire W12
    STUDIO_LOCK_OWNER=W12 python3 tools/qa/world2_check.py tour --world dino
    STUDIO_LOCK_OWNER=W10b-client python3 tools/qa/world2_check.py tour --world moon   # → docs/verification/moon/
    STUDIO_LOCK_OWNER=W12 python3 tools/qa/world2_check.py perf --world dino
    python3 scripts/studio-lock.py release W12
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

os.environ.setdefault("STUDIO_LOCK_OWNER", "W12")

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour  # noqa: E402  (require_lock, result, capture, sheet, stop_playtest)

SERVER = (ROOT / "tools/qa/world2_check.luau").read_text()
CLIENT = (ROOT / "tools/qa/world2_check_client.luau").read_text()
SERVER_COMMANDS = {"prepare", "admin", "where", "portal", "analytics", "perf", "fill", "unfill",
                   "visitor_touch", "focus", "unanchor", "restore", "money", "next_pad", "buy_next",
                   "until_finale", "portal_view", "npm_state", "npm_producer", "producer_view",
                   "main_buy_to"}
CLIENT_COMMANDS = {"state", "modal_close", "travel", "rebirth", "open", "camera", "camera_plot",
                   "camera_reset", "frame_ms", "swirl", "attack_ui", "gui_point", "open_panel", "admin_send",
                   "popup_state", "upgrade"}
WORLD_ID = re.compile(r"^[a-z][a-z0-9]{0,15}$")
# Capture folder: Dino Valley keeps its historical docs/verification/world2/; any other world gets
# docs/verification/<world>/ (set in main once --world is validated), so tours never overwrite each
# other's evidence.
OUT = ROOT / "docs/verification/world2"


def out_dir(world: str) -> Path:
    """The capture folder of a world (dino → world2, else the world id)."""
    return ROOT / "docs/verification" / ("world2" if world == "dino" else world)
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
# Admin codes (tools/qa/world2_check.luau ADMIN table).
RELOCK, UNLOCK, SET_AREA, UNLOCK_ALL, RESET_RUN, SET_REBIRTHS = 1, 2, 3, 4, 5, 6
SEND_SPAWN, SEND_PLOT, OFFLINE_PREVIEW, GRANT_CASH, REBUILD, SEND_HOME = 7, 8, 9, 10, 11, 12
ENABLED, WIPE, GRANT_MAIN_CASH, GRANT_GEMS, MAIN_SET_AREA, REBUILD_REPLAY = 13, 14, 15, 16, 17, 18

WORLD = "dino"


def render(template: str, command: str, allowed: set, args: list[float]) -> str:
    """Whitelisted command + validated world id + numeric args into a template (no free text)."""
    code = world_tour.render(template, command, allowed, args)
    return code.replace('"__WORLD__"', json.dumps(WORLD))


def server(command: str, args: list[float] | None = None) -> str:
    code = render(SERVER, command, SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def client(command: str, args: list[float] | None = None, target: str | None = None) -> str:
    payload = {"code": render(CLIENT, command, CLIENT_COMMANDS, args or [])}
    if target:
        payload["target"] = target
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", payload))


def admin(code: int, number: float = 0, player: int = 1) -> dict:
    reply = json.loads(server("admin", [code, number, player]))
    print(f"[w2] admin {code}({number}) p{player}: {reply}", flush=True)
    return reply


def shot(name: str, names: list[str]) -> None:
    world_tour.capture(OUT / f"{name}.jpg")
    names.append(f"{name}.jpg")
    print(f"[w2] {name}.jpg", flush=True)


def matrix(name: str, names: list[str], target: str = "client-1") -> None:
    """capture_device_matrix on a playtest client; one jpg per device (phone / tablet / console)."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": target, "format": "jpeg", "quality": 86, "settleSeconds": 1.2,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    for device, image in zip(DEVICES, images):
        file = f"{name}-{device['label']}.jpg"
        (OUT / file).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(file)
    if not images:
        print("[w2] matrix failed: " + json.dumps(response)[:300], flush=True)


def wait_client(predicate, seconds: float, target: str | None = None) -> dict:
    """Polls the client `state` until predicate(state) or the deadline; returns the last state."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("state", target=target))
            if predicate(last):
                return last
        except Exception as error:  # client VM not up yet / streaming
            last = {"error": str(error)[:200]}
        time.sleep(1.5)
    return last


def start_solo() -> None:
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    if '"running":true' in status.replace(" ", ""):
        raise SystemExit(f"a playtest is already running; not touching it: {status[:200]}")
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:160], flush=True)


def ready(state: dict) -> bool:
    return bool(state.get("loadingDone")) and state.get("plotIndex", 0) > 0


def in_world(world: str):
    return lambda state: state.get("currentWorld") == world and state.get("standingIn") == world


def look_at(target: list[float], away: list[float], distance: float, height: float, fov: float = 60) -> None:
    """Scriptable client camera `distance` studs from `target` toward `away` (+ height)."""
    dx, dz = away[0] - target[0], away[2] - target[2]
    length = max((dx * dx + dz * dz) ** 0.5, 1e-6)
    eye = [target[0] + dx / length * distance, target[1] + height, target[2] + dz / length * distance]
    client("camera", [*eye, target[0], target[1] + 3, target[2], fov])


def money() -> dict:
    return json.loads(server("money"))


def tour(record: dict, names: list[str]) -> None:
    record["ready"] = wait_client(ready, 150)
    time.sleep(5)
    record["prepare"] = json.loads(server("prepare"))
    client("modal_close")
    # 1. Unlock moment: relock (re-test the popup), unlock as admin, the popup opens once.
    record["relock"] = admin(RELOCK)
    record["unlock"] = admin(UNLOCK)
    record["popup"] = wait_client(lambda s: s.get("open", {}).get("WorldUnlocked"), 12)
    shot("01-unlock-popup", names)
    matrix("01-unlock-popup", names)
    client("modal_close")
    # 2. A FRESH Dino run (build-in on new pads) with Bones to spend.
    record["resetRun"] = admin(RESET_RUN)
    record["grantBones"] = admin(GRANT_CASH, 1_000_000)
    # 3. R60: money at home before the trip.
    record["moneyHome"] = money()
    # 4. The lobby Time Machine (W4's navy sign) + its swirl spinning.
    portals = json.loads(server("portal_view"))
    record["portals"] = portals
    lobby = portals.get("main")
    if lobby:
        centre = lobby["centre"]
        server("focus", [centre[0] + lobby["look"][0] * 30, centre[1], centre[2] + lobby["look"][2] * 30])
        time.sleep(3)
        away = [centre[0] + lobby["look"][0], centre[1], centre[2] + lobby["look"][2]]
        look_at(centre, away, 34, 10)
        time.sleep(2)
        shot("lobby-time-machine", names)
        record["lobbySwirl"] = json.loads(client("swirl", [*centre, 60]))
        client("camera_reset")
        server("unanchor")
    # 5. GO NOW = the travel intent to the world's spawn (Base Camp).
    client("travel", [1])
    record["arrive"] = wait_client(in_world(WORLD), 20)
    time.sleep(3)
    client("modal_close")
    shot("02-base-camp", names)
    matrix("02-base-camp", names)
    # 6. The Valley return portal + swirl; no attack UI anywhere in Dino Valley.
    valley = portals.get("world")
    if valley:
        centre = valley["centre"]
        away = [centre[0] + valley["look"][0], centre[1], centre[2] + valley["look"][2]]
        look_at(centre, away, 34, 10)
        time.sleep(2)
        shot("valley-return-portal", names)
        record["valleySwirl"] = json.loads(client("swirl", [*centre, 60]))
        client("camera_reset")
    record["attackUiInDino"] = json.loads(client("attack_ui"))
    # 7. Teleport screen with the world tabs.
    client("open", [1])
    time.sleep(1.2)
    shot("03-teleport-tabs", names)
    matrix("03-teleport-tabs", names)
    client("modal_close")
    # 8. Buy the next Dino pad on the fresh run: build-in mid-flight, then done.
    record["sendPlot"] = admin(SEND_PLOT)
    time.sleep(6)
    view = json.loads(server("next_pad"))
    record["nextPad"] = view
    if view.get("position") and view.get("entrance"):
        look_at(view["position"], view["entrance"], 26, 12)
        time.sleep(1.5)
    # The purchase is scheduled 0.3 s out so the screenshot (~1 s latency) lands mid-flight.
    record["buy"] = json.loads(server("buy_next", [0.3]))
    shot("04-dino-buildin-midflight", names)
    time.sleep(2.5)
    shot("04-dino-buildin-done", names)
    # R61: an upgrade with the producer billboard on screen (the bench just built).
    producer = json.loads(server("producer_view"))
    record["producerView"] = producer
    if producer.get("position") and producer.get("entrance"):
        look_at(producer["position"], producer["entrance"], 22, 10, 60)
    else:
        client("camera_plot", [1])
    time.sleep(1.5)
    shot("04a-r61-before-upgrade", names)
    record["upgrade"] = client("upgrade", [1])
    time.sleep(0.6)
    shot("04b-r61-upgrade-billboard", names)
    client("camera_reset")
    # 9. Home by the Valley's return portal (the real touch volume), then the R60 check.
    record["portalHome"] = server("portal", [2])
    record["home1"] = wait_client(in_world("main"), 20)
    after = money()
    record["moneyBack"] = after
    before = record["moneyHome"]
    elapsed = max(after["clock"] - before["clock"], 0.0)
    cash_delta = after["cash"] - before["cash"]
    earned_delta = after["totalEarned"] - before["totalEarned"]
    # Cash may only grow by Nuke Town's own income (no spend happened in Nuke Town; the Dino pad
    # was paid in Bones): delta == totalEarned delta, and within its income rate over the trip.
    record["r60"] = {
        "seconds": round(elapsed, 1),
        "cashDelta": cash_delta,
        "earnedDelta": earned_delta,
        "expectedMax": before["mainRate"] * elapsed * 1.25 + 1,
        "bonesDelta": after["worldCash"] - before["worldCash"],
        "padCost": record["buy"].get("cost"),
        "ok": abs(cash_delta - earned_delta) < 1e-6 * max(1.0, abs(cash_delta))
        and 0 <= cash_delta <= before["mainRate"] * elapsed * 1.25 + 1
        and after["tokens"] == before["tokens"] and after["gems"] == before["gems"],
    }
    print(f"[w2] R60: {record['r60']}", flush=True)
    shot("05-back-home", names)
    # The R62 six-button HUD + Rewards hub on devices (home, Nuke Town).
    client("modal_close")
    matrix("05a-hud-home", names)
    client("open", [4])
    time.sleep(1.2)
    shot("05b-rewards-hub", names)
    matrix("05b-rewards-hub", names)
    client("modal_close")
    # 10. The D6 finale pad label, from the path (every pad before it bought for free).
    client("travel", [1])
    wait_client(in_world(WORLD), 20)
    finale = json.loads(server("until_finale"))
    record["finalePad"] = finale
    admin(SEND_PLOT)
    time.sleep(4)
    if finale.get("position") and finale.get("entrance"):
        pos, ent = finale["position"], finale["entrance"]
        dx, dz = ent[0] - pos[0], ent[2] - pos[2]
        length = max((dx * dx + dz * dz) ** 0.5, 1e-6)
        # The character waits 45 studs down the path (behind the camera), so streaming covers the
        # pad and the shot shows the label, not the avatar standing on the pad.
        server("focus", [pos[0] + dx / length * 45, pos[1], pos[2] + dz / length * 45])
        time.sleep(3)
        look_at(pos, ent, 24, 9, 58)
        time.sleep(2)
        shot("06-d6-finale-pad-label", names)
        server("unanchor")
        client("camera_reset")
    # Build-in mid-flight on a whole plot: the admin rebuild REPLAYS every build-in (area 2 view).
    record["replay"] = admin(REBUILD_REPLAY)
    client("camera_plot", [2])
    time.sleep(1.2)
    shot("06b-dino-replay-buildin-1", names)
    time.sleep(1.5)
    shot("06c-dino-replay-buildin-2", names)
    client("camera_reset")
    # 11. Everything (finale), plot views.
    record["unlockAll"] = admin(UNLOCK_ALL)
    time.sleep(12)
    client("camera_plot", [0])
    time.sleep(3)
    shot("07-plot-full", names)
    client("camera_plot", [99])  # 99 = the world's last (finale) area, any area count
    time.sleep(2)
    shot("08-finale", names)
    client("camera_reset")
    # 12. Dino rebirth through the real intent (allowed: the finale pad is owned now).
    client("rebirth")
    time.sleep(4)
    record["afterRebirth"] = json.loads(server("where"))
    client("modal_close")
    shot("09-after-rebirth", names)
    # 13. Back home through the Valley's return portal (the real touch volume).
    record["portal"] = server("portal", [2])
    record["home"] = wait_client(in_world("main"), 20)
    time.sleep(2)
    client("modal_close")
    record["attackUiHome"] = json.loads(client("attack_ui"))
    shot("10-back-home", names)
    # 14. Welcome Back rows (read-only preview per world).
    record["offlinePreview"] = admin(OFFLINE_PREVIEW, 8)
    # 15. Analytics: the keys this tour must have produced.
    analytics = json.loads(server("analytics"))
    record["analytics"] = analytics
    worlds = analytics.get("worlds") or {}
    worlds = worlds if isinstance(worlds, dict) else {}
    expected = [f"unlock:{WORLD}", f"unlockSrc:{WORLD}:admin", f"step:{WORLD}:unlocked", f"area:{WORLD}:2",
                f"rebirth:{WORLD}", f"seconds:{WORLD}", "travel:main:portal"]
    record["analyticsMissing"] = [key for key in expected if worlds.get(key, 0) <= 0]
    core = analytics.get("core") or {}
    # An empty Luau table encodes as a JSON array.
    record["analyticsBadKeys"] = {k: v for k, v in (core.items() if isinstance(core, dict) else []) if k.startswith("ops:badKey")}


def rejoin(record: dict, names: list[str]) -> None:
    record["ready"] = wait_client(ready, 150)
    time.sleep(4)
    server("prepare")
    record["unlock"] = admin(UNLOCK)
    record["setArea"] = admin(SET_AREA, 3)
    record["home"] = admin(SEND_HOME)
    time.sleep(8)  # the profile autosave / leave save
    world_tour.stop_playtest()
    time.sleep(30)  # offline time (the payout floors to whole seconds)
    start_solo()
    record["ready2"] = wait_client(ready, 150)
    record["welcome"] = wait_client(lambda s: s.get("open", {}).get("WelcomeBack"), 20)
    shot("09-welcome-back", names)
    matrix("09-welcome-back", names)
    client("modal_close")
    server("prepare")


def click_gui(code: int) -> dict:
    """Clicks a GUI control of the playtest client (gui_point code) like a player would."""
    point = json.loads(client("gui_point", [code]))
    if point.get("found"):
        # simulate_mouse_input takes screenshot pixels; the client reports logical points.
        meta = studio_mcp.rpc("tools/call", {"name": "capture_screenshot",
                                              "arguments": {"format": "jpeg", "quality": 10}})
        width = (meta.get("structuredContent") or {}).get("width") or point["viewportX"]
        scale = width / max(point["viewportX"], 1)
        point["clickX"], point["clickY"] = round(point["x"] * scale), round(point["y"] * scale)
        studio_mcp.call_tool("simulate_mouse_input", {"action": "click", "x": point["clickX"], "y": point["clickY"]})
    return point


def npm(record: dict, names: list[str]) -> None:
    record["ready"] = wait_client(ready, 150)
    time.sleep(5)
    server("prepare")
    client("modal_close")
    # Real progress worth protecting: Dino unlocked, area 2, some Bones.
    record["unlock"] = admin(UNLOCK)
    record["setArea"] = admin(SET_AREA, 2)
    record["bones"] = admin(GRANT_CASH, 5000)
    time.sleep(2)
    real_before = json.loads(server("npm_state"))
    record["realBefore"] = real_before
    # 1. The header button on the Players tab (+ does a synthetic click reach a panel tab?).
    client("open_panel")
    time.sleep(1.5)
    shot("npm-01-header-button", names)
    matrix("npm-01-header-button", names)
    # Studio note (2026-10-31): simulate_mouse_input clicks do not reach Roblox GUI buttons in this
    # playtest (a plain panel tab ignores them too), so the panel's own send is used below; the
    # buttons themselves are verified on the captures.
    # 2. PLAY AS NEW PLAYER -> in-panel confirm -> CONFIRM (real clicks).
    entered = False
    record["entered"] = entered
    record["enteredVia"] = "click" if entered else "admin_send"
    if not entered:
        client("modal_close")
        record["sendEnter"] = client("admin_send", [1])
        deadline = time.time() + 25
        while time.time() < deadline and not entered:
            time.sleep(1.5)
            try:
                entered = json.loads(server("npm_state")).get("attribute") is True
            except Exception:
                pass
        record["entered"] = entered
    if not entered:
        # Lead (2026-10-31): never take "sandbox" captures of a profile that did not swap — fail
        # loudly with the server's view instead (npm_state + the result of the send).
        record["failure"] = "New Player Mode did not turn on (attribute stayed false)"
        record["stateAtFailure"] = json.loads(server("npm_state"))
        raise RuntimeError(record["failure"])
    time.sleep(6)  # the plot rebuilds from the empty profile
    client("modal_close")
    sandbox = json.loads(server("npm_state"))
    record["sandbox"] = sandbox
    shot("npm-03-sandbox-chip", names)
    matrix("npm-03-sandbox-chip", names)
    record["sandboxChecks"] = {
        "attributeOn": sandbox.get("attribute") is True and sandbox.get("sandbox") is True,
        "freshTycoon": sandbox.get("pads") == 0 and sandbox.get("rebirths") == 0,
        "dinoLocked": sandbox.get("worldUnlocked") is False and (sandbox.get("world") or {}).get("unlocked") is False,
        "noWorldsData": (sandbox.get("world") or {}).get("pads") == 0 and (sandbox.get("world") or {}).get("cash") == 0,
        "producerRunsWithoutClick": (sandbox.get("producer") or {}).get("before", {}).get("cycleStart")
        != (sandbox.get("producer") or {}).get("after", {}).get("cycleStart"),
    }
    # 3. A sandbox-only change (must never reach the real profile): cash + 7 gems; then the first
    # producer of a true new player, watched with no click (R64).
    record["sandboxGrant"] = admin(GRANT_MAIN_CASH, 12345)
    record["sandboxGems"] = admin(GRANT_GEMS, 7)
    record["firstProducer"] = json.loads(server("npm_producer"))
    shot("npm-03b-first-producer", names)
    # 4. EXIT (the chip's / header's send).
    exited = False
    record["exitedVia"] = "admin_send"
    if not exited:
        record["sendExit"] = client("admin_send", [2])
        deadline = time.time() + 25
        while time.time() < deadline and not exited:
            time.sleep(1.5)
            try:
                exited = json.loads(server("npm_state")).get("attribute") is False
            except Exception:
                pass
    record["exited"] = exited
    if not exited:
        record["failure"] = "New Player Mode did not turn off (attribute stayed true)"
        raise RuntimeError(record["failure"])
    time.sleep(6)
    client("modal_close")
    real_after = json.loads(server("npm_state"))
    record["realAfter"] = real_after
    shot("npm-04-exited", names)
    before_world, after_world = real_before.get("world") or {}, real_after.get("world") or {}
    record["restoreChecks"] = {
        "attributeOff": real_after.get("attribute") is False and real_after.get("sandbox") is False,
        "padsBack": real_after.get("pads") == real_before.get("pads"),
        "dinoBack": all(after_world.get(k) == before_world.get(k) for k in ("unlocked", "area", "pads", "rebirths")),
        # Cash is ~1e22 here (12,345 is below its float step), so the sandbox marker is 7 gems.
        "sandboxGemsNotSaved": real_after.get("gems") == real_before.get("gems"),
        "plotRebuilt": real_after.get("plotDescendants", -1) >= real_before.get("plotDescendants", 0) * 0.9,
    }


def wait_popup(seconds: float) -> dict:
    """Polls the client until WORLD UNLOCKED is open (or the deadline); returns the last probe."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("popup_state"))
            if last.get("open"):
                last["afterSeconds"] = round(seconds - (deadline - time.time()), 1)
                return last
        except Exception as error:  # client busy
            last = {"error": str(error)[:200]}
        time.sleep(1.0)
    return last


def popup(record: dict, names: list[str], trials: int) -> None:
    """World Unlocked reliability (lead: W5b saw a miss): `trials` fresh sessions each of
    (a) a NATURAL unlock at area 3 (New Player Mode sandbox: SetArea 3 -> WorldService rule) and
    (b) an ADMIN unlock (WorldRelock + WorldUnlock on the real profile), plus one same-session
    relock -> unlock repeat (the 'once per session' memory)."""
    runs = []
    for trial in range(1, trials + 1):
        for kind in ("natural", "admin"):
            if trial > 1 or kind == "admin":
                start_solo()
            row: dict = {"trial": trial, "kind": kind}
            try:
                row["ready"] = bool(wait_client(ready, 150).get("loadingDone"))
                time.sleep(4)
                server("prepare")
                client("modal_close")
                if kind == "natural":
                    client("admin_send", [1])
                    entered = False
                    deadline = time.time() + 25
                    while time.time() < deadline and not entered:
                        time.sleep(1.5)
                        try:
                            entered = json.loads(server("npm_state")).get("attribute") is True
                        except Exception:
                            pass
                    row["sandbox"] = entered
                    time.sleep(5)
                    client("modal_close")
                    # Real pad purchases (free) → AreaReached → WorldService's rule (source "area").
                    row["buyTo"] = json.loads(server("main_buy_to", [3]))
                else:
                    row["relock"] = admin(RELOCK)
                    time.sleep(2)
                    row["unlock"] = admin(UNLOCK)
                row["popup"] = wait_popup(20)
                row["shown"] = bool(row["popup"].get("open"))
                if row["shown"]:
                    shot(f"popup-{kind}-{trial}", names)
                    client("modal_close")
                if kind == "admin" and trial == trials:
                    # Same session, second relock -> unlock: does the popup come back?
                    row["repeatRelock"] = admin(RELOCK)
                    time.sleep(2)
                    row["repeatUnlock"] = admin(UNLOCK)
                    row["repeatPopup"] = wait_popup(15)
                    row["repeatShown"] = bool(row["repeatPopup"].get("open"))
                    client("modal_close")
                if kind == "natural":
                    client("admin_send", [2])
                    time.sleep(6)
            except Exception as error:
                row["error"] = str(error)[:300]
            finally:
                try:
                    server("restore")
                except Exception:
                    pass
                world_tour.stop_playtest()
            print(f"[w2] popup {kind} #{trial}: shown={row.get('shown')} {json.dumps(row.get('popup'))[:300]}", flush=True)
            runs.append(row)
    record["runs"] = runs
    record["summary"] = {
        kind: f"{sum(1 for r in runs if r['kind'] == kind and r.get('shown'))}/{sum(1 for r in runs if r['kind'] == kind)}"
        for kind in ("natural", "admin")
    }


def perf(record: dict, names: list[str]) -> None:
    record["ready"] = wait_client(ready, 150)
    time.sleep(4)
    server("prepare")
    record["baseline"] = json.loads(server("perf"))
    record["fillMain"] = json.loads(world_render_fill("main"))
    record["unlock"] = admin(UNLOCK)
    record["unlockAll"] = admin(UNLOCK_ALL)
    record["fillWorld"] = json.loads(server("fill"))
    # Steady state: the 8 + 8 plots finish their mesh restores first (the first samples are the
    # build burst). Poll every 10 s until the Workspace count holds for two samples (max 150 s).
    samples = []
    last = -1
    for _ in range(15):
        time.sleep(10)
        sample = json.loads(server("perf"))
        samples.append({k: sample.get(k) for k in ("fps", "heartbeatAvgMs", "workspaceDescendants", "memoryMb")})
        if sample.get("workspaceDescendants") == last:
            break
        last = sample.get("workspaceDescendants")
    record["fillSamples"] = samples
    time.sleep(10)
    record["full"] = json.loads(server("perf"))
    client("modal_close")
    client("travel", [1])
    record["arrive"] = wait_client(in_world(WORLD), 20)
    time.sleep(6)
    # Low FX tier = Automatic quality on a phone (FxQuality): phone preset active while sampling.
    studio_mcp.call_tool("set_device_simulator", {"target": "client-1", "deviceId": "iphone_14",
                                                  "orientation": "LandscapeRight"})
    time.sleep(3)
    record["valleyClientPhone"] = json.loads(client("frame_ms", [8]))
    shot("10-valley-perf-phone", names)
    studio_mcp.call_tool("set_device_simulator", {"target": "client-1", "stopSimulation": True})
    record["valleyClientDesktop"] = json.loads(client("frame_ms", [8]))
    record["memory"] = studio_mcp.call_tool("get_memory_breakdown", {"target": "all"})[:4000]
    record["unfill"] = [server("unfill"), world_render_unfill("main")]


def world_render_fill(world: str) -> str:
    """Runs `fill` for another world id (validated) without changing the tour's WORLD."""
    global WORLD
    saved, WORLD = WORLD, world
    try:
        return server("fill")
    finally:
        WORLD = saved


def world_render_unfill(world: str) -> str:
    global WORLD
    saved, WORLD = WORLD, world
    try:
        return server("unfill")
    finally:
        WORLD = saved


def main() -> int:
    global WORLD
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    # No multiplayer mode: OWNER ORDER 2026-10-31 "stop running multiplayer playtests" (an 8-client
    # run that failed to start left its peers running for hours). Visits are checked solo.
    parser.add_argument("mode", choices=("tour", "rejoin", "perf", "npm", "popup"))
    parser.add_argument("--trials", type=int, default=3, help="popup mode: fresh sessions per unlock kind")
    parser.add_argument("--world", default="dino")
    args = parser.parse_args()
    if not WORLD_ID.match(args.world) or args.world == "main":
        raise SystemExit("--world must be an extra world id (e.g. dino)")
    WORLD = args.world
    global OUT
    OUT = out_dir(WORLD)
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"mode": args.mode, "world": WORLD, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    names: list[str] = []
    began = time.time()
    try:
        if args.mode == "popup":
            start_solo()
            popup(record, names, max(1, min(5, args.trials)))
        else:
            start_solo()
            try:
                if args.mode == "tour":
                    tour(record, names)
                elif args.mode == "rejoin":
                    rejoin(record, names)
                elif args.mode == "npm":
                    npm(record, names)
                else:
                    perf(record, names)
            finally:
                try:
                    client("camera_reset")
                    server("unanchor")
                    if args.mode == "rejoin":
                        # Back to a fresh Dino state (the rejoin changed the saved test profile).
                        record["reset"] = [admin(WIPE), admin(RELOCK)]
                    else:
                        record["restore"] = server("restore")
                except Exception as error:  # restore must not hide the original failure
                    record["restoreError"] = str(error)[:300]
                world_tour.stop_playtest()
    finally:
        record["seconds"] = round(time.time() - began, 1)
        (OUT / f"{args.mode}.json").write_text(json.dumps(record, indent=2) + "\n")
        if names:
            world_tour.sheet(OUT, names, OUT / f"{args.mode}-sheet.jpg", cols=4, width=480)
    print(json.dumps({k: record[k] for k in record if k not in ("analytics", "memory")}, indent=1)[:6000])
    return 0


if __name__ == "__main__":
    sys.exit(main())
