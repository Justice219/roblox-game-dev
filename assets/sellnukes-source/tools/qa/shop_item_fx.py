#!/usr/bin/env python3
"""
shop_item_fx.py — owner R98 check: Shop items sit on readable backing plates (dark disc + glow
ring + halo + shadow, captions on dark name-plates) and gently animate (staggered bob + pulse,
sparkle glints on rare items), only while the Shop is open, parked by Reduce Motion.
One solo playtest in the open place (hold the Studio lock; never run while someone else's
playtest is going).

    python3 scripts/studio-lock.py acquire S-shop
    STUDIO_LOCK_OWNER=S-shop python3 tools/qa/shop_item_fx.py
    python3 scripts/studio-lock.py release S-shop

Steps (client half: tools/qa/shop_item_fx_client.luau, whitelisted commands only):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the loading screen + plot reveal
    3. open the Shop on the LIMITED section (Starter + Secret Pack): probe plates / captions,
       sample the motion (every on-screen item must bob), watch the glints (rare tiles sparkle,
       one at a time per pack), two desktop shots 0.6 s apart (different bob phases)
    4. every grid section (passes .. boosts): desktop shot + motion sample
    5. device matrix (phone / tablet / console) of LIMITED and CASH
    6. Reduce Motion on -> items at rest (offset 0, scale 1, no glint), shot; then back to the
       profile's own setting
    7. close the Shop -> no item animator running, items at rest
    8. stop the playtest (always)
Outputs -> docs/verification/r98-shop-items/ (jpgs + shop-item-fx.json).
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

CLIENT = (ROOT / "tools/qa/shop_item_fx_client.luau").read_text()
COMMANDS = {"ready", "open", "probe", "motion", "glints", "reduce", "close"}
OUT = ROOT / "docs/verification/r98-shop-items"
# ShopConfig.Sections order (1 = limited packs; the grid sections follow).
SECTIONS = {"limited": 1, "passes": 2, "cash": 3, "gems": 4, "spins": 5, "boosts": 6}
# Built-in Studio device presets, one capture call per device (one failing preset never drops the others).
DEVICES = [
    {"label": "phone", "deviceId": "iphone_13", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "hd_1080"},
]


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client, one device per call; one jpg each."""
    names = []
    for device in DEVICES:
        response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
            "entries": [device], "target": "client-1", "format": "jpeg", "quality": 86,
            "settleSeconds": 1.5, "restoreAfter": True,
        }})
        images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
        if images:
            path = OUT / f"{prefix}-{device['label']}.jpg"
            path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
            names.append(str(path.relative_to(ROOT)))
        else:
            names.append(f"{device['label']} failed: " + json.dumps(response)[:240])
    return names


def step(record: dict, label: str, action):
    """Runs one check step; a failure is logged instead of aborting (stop + JSON must still happen)."""
    try:
        return action()
    except Exception as error:  # noqa: BLE001 - QA runner: record and continue
        record["log"].append(f"{label} failed: {str(error)[:300]}")
        print(f"[r98] {label} failed: {error}", flush=True)
        return None


def summarize(record: dict) -> list[str]:
    """Pass / fail lines for the lead (read from the recorded probes)."""
    lines: list[str] = []
    probe = record.get("probeLimited") or {}
    slots = probe.get("slots", [])
    plated = sum(1 for s in slots if s.get("plate") and s.get("halo") and s.get("shadow"))
    lines.append(f"plates: {plated}/{len(slots)} slots have plate + ring + halo + shadow")
    captions = probe.get("captions", [])
    unplated = [c["owner"] for c in captions if not c.get("plated")]
    unfit = [f"{c['owner']} {c['text']!r}" for c in captions if not c.get("fits")]
    lines.append(f"captions: {len(captions) - len(unplated)}/{len(captions)} plated; not fitting: {unfit or 'none'}")
    lines.append(f"info plates: {probe.get('infoPlates')}")
    motion = record.get("motionLimited") or {}
    lines.append(f"motion (limited): {motion.get('moving')}/{motion.get('onScreen')} on-screen items bob")
    glints = record.get("glintsLimited") or {}
    lines.append(f"glints: {len(glints.get('glinted', []))}/{glints.get('rareOnScreen')} rare items sparkled; "
                 f"most at once {glints.get('mostAtOnce')}")
    reduced = record.get("reduced") or {}
    resting = [s for s in reduced.get("slots", []) if s.get("onScreen")]
    still = sum(1 for s in resting if s.get("y") == 0 and s.get("scale") in (1, None) and not s.get("glintVisible"))
    lines.append(f"reduce motion: {still}/{len(resting)} on-screen items at rest")
    closed = record.get("afterClose") or {}
    lines.append(f"after close: OfferFx {closed.get('offerFx')}")
    return lines


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
    record: dict = {"log": [], "sections": {}}
    started = time.time()
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:100])
    try:
        time.sleep(3)
        state = "waiting"
        for _ in range(8):  # loading screen + plot reveal: up to ~160 s in 20 s polls
            state = client("ready", [20])
            if state == "ready":
                break
        record["log"].append(f"client {state}")
        record["log"].append(client("open", [SECTIONS["limited"]]))
        time.sleep(2.0)  # pop-in + first model loads
        record["probeLimited"] = step(record, "probe limited", lambda: json.loads(client("probe")))
        record["motionLimited"] = step(record, "motion limited", lambda: json.loads(client("motion", [2.5])))
        record["glintsLimited"] = step(record, "glints limited", lambda: json.loads(client("glints", [4])))
        record["shotsLimited"] = [shot("r98-limited-a")]
        time.sleep(0.6)
        record["shotsLimited"].append(shot("r98-limited-b"))
        for name, index in SECTIONS.items():
            if name == "limited":
                continue
            client("open", [index])
            time.sleep(1.2)
            record["sections"][name] = {
                "shot": step(record, f"shot {name}", lambda n=name: shot(f"r98-{n}")),
                "motion": step(record, f"motion {name}", lambda: json.loads(client("motion", [1.5]))),
            }
        client("open", [SECTIONS["limited"]])
        time.sleep(1.0)
        record["matrixLimited"] = step(record, "matrix limited", lambda: matrix("r98-limited"))
        client("open", [SECTIONS["cash"]])
        time.sleep(1.0)
        record["matrixCash"] = step(record, "matrix cash", lambda: matrix("r98-cash"))
        # Reduce Motion parks the items at rest.
        client("open", [SECTIONS["limited"]])
        time.sleep(1.0)
        record["log"].append(client("reduce", [1]))
        time.sleep(0.6)
        record["reduced"] = step(record, "probe reduced", lambda: json.loads(client("probe")))
        record["reducedShot"] = step(record, "shot reduced", lambda: shot("r98-limited-reduced-motion"))
        record["log"].append(client("reduce", [0]))
        time.sleep(0.6)
        record["log"].append(client("close"))
        time.sleep(1.2)
        record["afterClose"] = step(record, "probe after close", lambda: json.loads(client("probe")))
    except Exception as error:
        record["log"].append(f"aborted: {str(error)[:300]}")
        raise
    finally:
        try:
            client("reduce", [0])  # never leave QA's Reduce Motion behind
        except Exception:  # noqa: BLE001 - best effort before stopping
            pass
        record["seconds"] = round(time.time() - started, 1)
        record["summary"] = summarize(record)
        (OUT / "shop-item-fx.json").write_text(json.dumps(record, indent=2) + "\n")
        world_tour.stop_playtest()
    for line in record["summary"]:
        print(f"[r98] {line}")
    print(f"[r98] outputs -> {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
