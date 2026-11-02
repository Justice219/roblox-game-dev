#!/usr/bin/env python3
"""
shop_world.py — Studio check of one world's Shop section (R57 Dino Valley / R70 MOON BASE): the
section shows once the world is unlocked, every card has its REAL 3D prop (R39), live price / COMING
SOON button, currency preview, gamepad links, and the section reads on phone / tablet / console.
One solo playtest in the open place (hold the Studio lock).

    STUDIO_LOCK_OWNER=W1b python3 scripts/studio-lock.py acquire W1b
    STUDIO_LOCK_OWNER=W1b python3 tools/qa/shop_world.py --world moon
    python3 scripts/studio-lock.py release W1b

Steps:
    1. wait for the loading screen + plot reveal (client), unlock WORLD for the test player through
       the admin pipeline (server; remembered so it is relocked afterwards if it was locked)
    2. open the Shop on the world section, wait for its model templates, record every card
       (tools/qa/shop_models_client.luau `world_cards`), capture shop-<world>.jpg
    3. phone / tablet / console captures (device simulator, re-scrolled to the section each time)
    4. close the Shop, restore the world lock, stop the playtest
Outputs -> docs/verification/world-qa/shop/ (shop-<world>*.jpg, shop-<world>.json).
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402
import world_tour  # noqa: E402  (require_lock, render, result, capture, stop_playtest)

CLIENT = (ROOT / "tools/qa/shop_models_client.luau").read_text()
SERVER = (ROOT / "tools/qa/shop_world_server.luau").read_text()
CLIENT_COMMANDS = {"ready", "open_world", "wait", "world_cards", "close"}
SERVER_COMMANDS = {"unlock", "restore", "state"}
OUT = ROOT / "docs/verification/world-qa/shop"
DEVICES = [
    {"label": "phone", "deviceId": "iphone_13", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "hd_1080"},
]


def world_sections() -> list[str]:
    """The ShopConfig.WorldSections ids in order (parsed from the config source)."""
    source = (ROOT / "src/shared/Config/ShopConfig.luau").read_text()
    block = source.split("local WORLD_SECTIONS", 1)[1].split("ShopConfig.WorldSections", 1)[0]
    return re.findall(r'id = "([a-z0-9_]+)",\s*world = ', block)


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(command: str, world: str) -> str:
    if command not in SERVER_COMMANDS or not re.fullmatch(r"[a-z0-9_]+", world):
        raise SystemExit("bad server command / world")
    code = SERVER.replace('"__COMMAND__"', json.dumps(command)).replace('"__WORLD__"', json.dumps(world))
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def matrix(prefix: str, index: int) -> list[str]:
    """
    Phone / tablet / console captures of the world section: each device is switched on with
    set_device_simulator, the Shop is re-scrolled to the section (a device switch re-lays the
    list out, which moves the scroll position), then the viewport is captured. Simulation is
    stopped afterwards.
    """
    names = []
    try:
        for device in DEVICES:
            settings = {key: value for key, value in device.items() if key != "label"}
            studio_mcp.call_tool("set_device_simulator", {"target": "client-1", **settings})
            time.sleep(1.5)
            client("open_world", [index])
            time.sleep(1.8)
            name = f"{prefix}-{device['label']}.jpg"
            world_tour.capture(OUT / name)
            names.append(name)
    finally:
        try:
            studio_mcp.call_tool("set_device_simulator", {"target": "client-1", "stopSimulation": True})
        except RuntimeError as error:
            names.append(f"stop simulation: {str(error)[:160]}")
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--world", default="moon")
    args = parser.parse_args()
    sections = world_sections()
    if args.world not in sections:
        raise SystemExit(f"no Shop section for world {args.world} (sections: {sections})")
    index = sections.index(args.world) + 1
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"world": args.world, "log": []}
    started = time.time()
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:100])
    try:
        time.sleep(3)
        state = "waiting"
        for _ in range(8):  # loading screen + plot reveal, in 20 s polls (MCP request timeout ~30 s)
            state = client("ready", [20])
            if state == "ready":
                break
        record["log"].append(f"client {state}")
        record["log"].append(server("unlock", args.world))
        time.sleep(2.5)  # the profile push reaches the client
        record["log"].append(client("open_world", [index]))
        record["load"] = json.loads(client("wait", [25]))
        time.sleep(1.5)
        record["cards"] = json.loads(client("world_cards", [index]))
        world_tour.capture(OUT / f"shop-{args.world}.jpg")
        record["matrix"] = matrix(f"shop-{args.world}", index)
        record["cardsAfter"] = json.loads(client("world_cards", [index]))
        record["log"].append(client("close"))
    except Exception as error:
        record["log"].append(f"aborted: {str(error)[:300]}")
        raise
    finally:
        try:
            record["log"].append(server("restore", args.world))
        except Exception as error:  # restoring must not hide the original failure
            record["log"].append(f"restore failed: {str(error)[:200]}")
        record["seconds"] = round(time.time() - started, 1)
        (OUT / f"shop-{args.world}.json").write_text(json.dumps(record, indent=2) + "\n")
        world_tour.stop_playtest()
    cards = (record.get("cards") or {}).get("cards", [])
    print(f"[shop-world] {args.world}: " + ", ".join(
        f"{c['key']} {c.get('model')} '{c.get('buttonText')}' {c.get('buttonSize')}" for c in cards))
    print(f"[shop-world] log {record['log']} matrix {record.get('matrix')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
