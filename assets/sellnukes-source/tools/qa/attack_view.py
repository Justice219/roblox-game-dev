#!/usr/bin/env python3
"""
attack_view.py — Studio QA for owner R104 / R105 / R106 (docs/attack.md §20):
    R104  the attack target picker streams the target base in (Server/Attack/PickerFocus replication
          focus + Client/Attack/PickerView) and shows "LOADING BASE..." until it is there
    R105  defence pad / tower billboards stay clear of producer billboards (Client/Attack/
          DefenseBoardPlacement + DefenseWorld's runtime declutter)
    R106  AA towers idle-animate, slew onto nukes, recoil + muzzle flash (Client/Attack/TowerAnim)
    R109  the launching silo's rocket lifts off, hands over to the flight, the gantry reloads
          (Client/Attack/SiloLaunch)
    R118  picker aim chips never overlap (pinned + de-collided with leader lines, or one tidy row),
          the info / status / aim lines stack (Screens/AttackTarget/PickerLayout + AttackScreen)
One SOLO playtest in the open place (hold the Studio lock; never multiplayer, owner R72). Prints one
JSON record; captures go to docs/verification/r104-attack-view/.

Steps:
    1. start a solo Play playtest, wait for the HUD + the first profile push
    2. setup (defense_towers_server.luau): area 9 (HQ tower + every defence slot open), every slot
       tower at L3; an admin test bot on a free plot (a target across the hub = outside the
       player's stream radius, the R104 repro)
    3. R104: open the picker → LOADING plate → loaded (reason, seconds, BaseParts in the target's
       container) → the server focus streams that slot → capture + device matrix; cycle targets with
       the REAL Right-arrow binding (bot plot, the Rival islands), capture each once loaded; junk
       AttackPickerFocus intents change nothing; close → the focus lingers, then is dropped
    4. R105: four camera views around the Launch Silos / Back Tower (the owner's screenshot): the
       live screen audit (defence boards vs producer boards, defence vs defence) must report no
       clips; captures + a device matrix of the Silo view
    5. R106: the HQ tower close-up — poses change over 1.5 s (idle scan), two captures; an admin
       test nuke → towers engage + muzzle flashes (capture mid-engagement); Reduce Motion → towers
       ease back to rest; restored
    6. R109: camera on my Launch Silos; a REAL launch at Rival 1 (AttackClient.launch → server) →
       captures at ignite (t0 - 0.6), lift-off (t0 + 0.4) and mid-reload (t0 + 6): the rocket left,
       the gantry is empty, a fresh rocket rises under the RELOADING glow + board; SiloLaunch stats
       (launching / reloading / clones / boards) and the real rockets' LocalTransparencyModifier
    7. remove the bot, restore cash + attack, stop the playtest (only ours)
Modes:
    (none)  the full pass above
    picker  steps 1-3 + 7 only
    boards  steps 1, 2, 4 + 7 only
    anim    steps 1, 2, 5 + 7 only
    silo    steps 1, 2, 6 + 7 only (alias: r109)
    r118    steps 1, 2 + the R118 layout pass + 7: open the picker, walk EVERY target with the real
            Right-arrow binding (the bot plot, the four Rival islands incl. Mega Meltdown Mart):
            live audit per target (chip overlaps, labels fit, chip px vs 44 pt, info-line overlaps)
            + a capture; device matrices (phone / tablet / console / desktop) of a Rival island and
            the bot plot, each with its audit
Usage:
    python3 scripts/studio-lock.py acquire <owner>
    STUDIO_LOCK_OWNER=<owner> python3 tools/qa/attack_view.py [picker|boards|anim|silo|r109|r118]
    python3 scripts/studio-lock.py release <owner>
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

DT_SERVER = (ROOT / "tools/qa/defense_towers_server.luau").read_text()
DT_SERVER_COMMANDS = {"prepare", "state", "area", "grant", "testnuke", "restore"}
AV_SERVER = (ROOT / "tools/qa/attack_view_server.luau").read_text()
AV_SERVER_COMMANDS = {"bot", "bots_clear", "focus_stats", "plot"}
CLIENT = (ROOT / "tools/qa/attack_view_client.luau").read_text()
CLIENT_COMMANDS = {
    "diag", "close_all", "picker_open", "picker_state", "picker_wait", "hostile_focus", "camera_at",
    "camera_reset", "boards", "anim", "anim_delta", "reduced", "watch_fire", "silo_launch", "silo_state",
    "silo_watch", "picker_audit",
}
OUT = ROOT / "docs/verification/r104-attack-view"
# Seconds the server keeps a closed picker's focus (AttackConfig.Client.PickerStream.FocusLinger).
FOCUS_LINGER = 22

DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
    {"label": "desktop", "deviceId": "hd_1080"},
]

# R105 camera views, PLOT-LOCAL (eye xyz, look xyz) around the Launch Silos (area 7 + Silo slot 3
# at x -95 z 335, HQ tower at x -32 z 402) and the Back Tower (slot 4, x 95 z 445).
VIEWS = {
    "silo-road": [0, 8, 330, -95, 6, 335],
    "silo-inside": [-20, 9, 360, -95, 6, 335],
    "silo-flank": [-110, 8, 300, -40, 8, 380],
    "back-road": [40, 8, 445, 95, 6, 445],
}


def dt_server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(DT_SERVER, command, DT_SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def av_server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(AV_SERVER, command, AV_SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def js(text: str) -> object:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def capture(name: str) -> str:
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 88}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not images:
        return "capture failed"
    path = OUT / name
    path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
        "restoreAfter": False,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(DEVICES, images):
        name = f"{prefix}-{device['label']}.jpg"
        (OUT / name).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str((OUT / name).relative_to(ROOT)))
    if not images:
        names.append("matrix failed: " + json.dumps(response)[:300])
    return names


def key(code: str) -> str:
    return studio_mcp.call_tool("simulate_keyboard_input", {"keyCode": code, "action": "tap", "target": "client-1"})[:120]


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


def setup(record: dict) -> None:
    record["prepare"] = js(dt_server("prepare"))
    record["area9"] = js(dt_server("area", [9]))
    record["grant"] = js(dt_server("grant", [3]))
    record["bot"] = js(av_server("bot", [9, 3]))
    time.sleep(6.0)  # the bot plot builds in the background, towers fly in
    client("close_all")
    record["plot"] = js(av_server("plot"))


def r104(record: dict) -> None:
    """Picker streaming + loading plate + server focus lifecycle."""
    picker: dict = {"targets": []}
    record["r104"] = picker
    picker["open"] = js(client("picker_open"))
    picker["first"] = js(client("picker_wait", [12]))
    picker["focus"] = js(av_server("focus_stats"))
    picker["shot1"] = capture("r104-picker-1.jpg")
    picker["matrix"] = matrix("r104-picker")
    for index in range(2, 7):
        log = key("Right")
        time.sleep(0.25)
        during = js(client("picker_state"))
        after = js(client("picker_wait", [12]))
        time.sleep(0.6)  # let the camera tween settle
        picker["targets"].append({
            "key": log, "during": during, "after": after, "focus": js(av_server("focus_stats")),
            "shot": capture(f"r104-picker-{index}.jpg"),
        })
    before = js(av_server("focus_stats"))
    client("hostile_focus")
    time.sleep(1.0)
    picker["hostile"] = {"before": before, "after": js(av_server("focus_stats"))}
    client("close_all")
    time.sleep(1.5)
    picker["closedLinger"] = js(av_server("focus_stats"))
    time.sleep(FOCUS_LINGER + 2.5)
    picker["closedDropped"] = js(av_server("focus_stats"))
    picker["clientAfterClose"] = js(client("diag"))


def r105(record: dict) -> None:
    """Defence boards vs producer boards from the owner's angles."""
    boards: dict = {}
    record["r105"] = boards
    for name, view in VIEWS.items():
        client("camera_at", view)
        time.sleep(1.2)
        boards[name] = {"audit": js(client("boards")), "shot": capture(f"r105-{name}.jpg")}
    client("camera_at", VIEWS["silo-inside"])
    time.sleep(1.0)
    boards["siloMatrix"] = matrix("r105-silo-inside")
    boards["siloMatrixAudit"] = js(client("boards"))
    client("camera_reset")


def r106(record: dict) -> None:
    """Idle scan, engagement + muzzle flashes, Reduce Motion."""
    anim: dict = {}
    record["r106"] = anim
    client("camera_at", [0, 14, 380, -32, 8, 402])
    time.sleep(1.0)
    anim["stats"] = js(client("anim"))
    anim["idleA"] = capture("r106-idle-a.jpg")
    anim["delta"] = js(client("anim_delta", [1.5]))
    anim["idleB"] = capture("r106-idle-b.jpg")
    anim["testnuke"] = dt_server("testnuke")[:200]
    time.sleep(5.2)  # lead-in + into the flight: towers slewing, interceptors leaving
    anim["fireShot"] = capture("r106-engage.jpg")
    anim["watch"] = js(client("watch_fire", [5]))
    time.sleep(2.0)
    client("reduced", [1])
    time.sleep(3.5)
    anim["reduced"] = js(client("anim"))
    anim["reducedShot"] = capture("r106-reduced-rest.jpg")
    client("reduced", [0])
    time.sleep(1.5)
    anim["restored"] = js(client("anim_delta", [1.0]))
    client("camera_reset")


def r109(record: dict) -> None:
    """Silo rocket lift-off + hand-off + reload (owner R109)."""
    silo: dict = {}
    record["r109"] = silo
    client("camera_at", [25, 26, 364, -60, 16, 364])  # across the road from Area 7: the three gantries
    time.sleep(1.5)
    silo["before"] = js(client("silo_state"))
    silo["beforeShot"] = capture("r109-silos-ready.jpg")
    silo["launch"] = js(client("silo_launch"))
    lead_in = 3.4  # AttackConfig.Flight.LeadIn: t0 = send + lead-in
    time.sleep(lead_in - 0.6)
    silo["igniteShot"] = capture("r109-ignite.jpg")
    silo["ignite"] = js(client("silo_state"))
    time.sleep(1.0)
    silo["liftoffShot"] = capture("r109-liftoff.jpg")
    time.sleep(1.0)
    silo["gone"] = js(client("silo_state"))
    time.sleep(4.0)
    silo["reloadShot"] = capture("r109-reloading.jpg")
    silo["reload"] = js(client("silo_state"))
    silo["reloadMatrix"] = matrix("r109-reloading")
    silo["watch"] = js(client("silo_watch", [3]))
    client("camera_reset")


def r118(record: dict) -> None:
    """Picker layout: aim chips + stacked info lines on every target (owner R118)."""
    layout: dict = {"targets": []}
    record["r118"] = layout
    client("picker_open")
    js(client("picker_wait", [12]))
    seen: set[str] = set()
    for index in range(14):  # 1 bot + 4 rivals + any players, wraps around
        time.sleep(0.8)  # camera tween + one layout pass
        audit = js(client("picker_audit"))
        name = audit.get("state", {}).get("name", "") if isinstance(audit, dict) else ""
        entry = {"name": name, "audit": audit, "shot": capture(f"r118-target-{index + 1}.jpg")}
        layout["targets"].append(entry)
        if name and name in seen:
            break
        seen.add(name)
        if "Mega Meltdown" in name and "rivalMatrix" not in layout:
            layout["rivalMatrix"] = matrix("r118-mega-meltdown")
            layout["rivalMatrixAudit"] = js(client("picker_audit"))
        if "[BOT]" in name and "plotMatrix" not in layout:
            layout["plotMatrix"] = matrix("r118-bot-plot")
            layout["plotMatrixAudit"] = js(client("picker_audit"))
        key("Right")
        js(client("picker_wait", [12]))
    layout["clips"] = sum(
        len(t["audit"].get("chipClips", [])) + len(t["audit"].get("lineClips", []))
        for t in layout["targets"] if isinstance(t["audit"], dict)
    )
    client("close_all")


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if mode == "r109":
        mode = "silo"
    if mode not in {"all", "picker", "boards", "anim", "silo", "r118"}:
        raise SystemExit("usage: attack_view.py [picker|boards|anim|silo|r109|r118]")
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"mode": mode, "log": []}
    record["log"].append(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)  # first profile push + boot windows
        client("close_all")
        setup(record)
        if mode in {"all", "picker"}:
            r104(record)
        if mode in {"all", "boards"}:
            r105(record)
        if mode in {"all", "anim"}:
            r106(record)
        if mode in {"all", "silo"}:
            r109(record)
        if mode in {"all", "r118"}:
            r118(record)
    finally:
        for step, call in (
            ("reducedOff", lambda: client("reduced", [0])),
            ("cameraReset", lambda: client("camera_reset")),
            ("botsClear", lambda: av_server("bots_clear")),
            ("restore", lambda: dt_server("restore")),
        ):
            try:
                record[step] = js(call())
            except Exception as error:  # report, still stop our playtest
                record[step] = {"error": str(error)[:200]}
        world_tour.stop_playtest()
    print(json.dumps(record, indent=1, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
