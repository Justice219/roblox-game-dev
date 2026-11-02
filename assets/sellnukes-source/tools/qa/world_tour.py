#!/usr/bin/env python3
"""
world_tour.py — World-QA camera tour: builds a plot through the REAL game code in a Studio solo
playtest and captures a fixed shot list for visual review.

Flow (all via the Studio MCP on localhost, scripts/studio_mcp.py transport):
    1. refuses to run unless `scripts/studio-lock.py` shows LOCK_OWNER (env STUDIO_LOCK_OWNER, default W1) holding the lock (no --skip-lock)
    2. starts a solo playtest; server `prepare` (plot ready, hub built, profile snapshot)
    3. client `hud_off` (world-only shots; in-world billboards stay)
    4. PARTIAL: TycoonAdmin.resetPlot + setArea(4) + rebuildPlot -> areas 1-3 shots
    5. FULL:    TycoonAdmin.unlockAll + rebuildPlot -> hub x2, entrance, every area x2, plot aerial,
                8-plot ring aerial; then the live ZFight audit (owner R18): zfight.json (count +
                offenders) and close-ups zfight_NN.jpg of the first six
    6. restore the test profile (pads + cash), stop the playtest
    7. writes <out>/shots.json and contact sheets (sheet_partial.jpg, sheet_full.jpg)

Shot positions come from WorldLayout inside the server `plan` command (tools/qa/world_tour.luau),
so the tour follows the real layout. Each shot: server `focus` (character anchored near the subject,
RequestStreamAroundAsync) -> client `camera` -> settle -> capture_screenshot.

Usage:
    python3 scripts/studio-lock.py acquire W1
    python3 tools/qa/world_tour.py [--out docs/verification/world-qa/<stamp>] [--only full|partial]
    python3 scripts/studio-lock.py release W1
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import studio_mcp  # noqa: E402  (localhost-only MCP transport)

# Studio lock owner the QA scripts expect (scripts/studio-lock.py). Override with STUDIO_LOCK_OWNER
# when another agent name holds the lock, e.g. `STUDIO_LOCK_OWNER=W1 python3 tools/qa/world_tour.py`.
LOCK_OWNER = os.environ.get("STUDIO_LOCK_OWNER", "W1")


def require_lock() -> None:
    """Exit unless LOCK_OWNER holds the Studio lock (one playtesting agent at a time)."""
    status = subprocess.run([sys.executable, str(ROOT / "scripts/studio-lock.py"), "status"],
                            capture_output=True, text=True, check=False).stdout
    try:
        owner = json.loads(status.splitlines()[0]).get("owner") if status.strip() else None
    except (json.JSONDecodeError, IndexError, AttributeError):
        owner = None
    if owner != LOCK_OWNER:
        raise SystemExit(f"hold the Studio lock first: python3 scripts/studio-lock.py acquire {LOCK_OWNER} "
                         f"(held by {owner!r}; set STUDIO_LOCK_OWNER to match)")


SERVER = (ROOT / "tools/qa/world_tour.luau").read_text()
CLIENT = (ROOT / "tools/qa/world_tour_client.luau").read_text()
SERVER_COMMANDS = {"prepare", "partial", "full", "plan", "focus", "zfight", "restore"}
CLIENT_COMMANDS = {"hud_off", "camera", "hud_on"}
PARTIAL_SHOTS = ("partial_overview", "partial_road", "plot_entrance", "area01_road", "area02_road", "area03_road")


def stop_playtest(timeout: int = 90) -> None:
    """Stops OUR playtest; a slow Studio teardown is reported, never raised (outputs are already
    written and the next status call shows edit mode once the teardown settles)."""
    try:
        print(studio_mcp.call_tool("solo_playtest", {"action": "stop", "timeout": timeout})[:120])
    except RuntimeError as error:
        print(f"[qa] stop: {str(error)[:200]}", flush=True)
        for _ in range(15):
            time.sleep(2)
            status = json.loads(studio_mcp.call_tool("solo_playtest", {"action": "status"}))
            if not status.get("running"):
                print("[qa] playtest stopped (teardown settled)", flush=True)
                return
        print("[qa] WARNING: playtest still tearing down", flush=True)


def render(template: str, command: str, allowed: set, args: list[float]) -> str:
    """Fill the whitelisted command + numeric args into a Luau template (no free-form text)."""
    if command not in allowed:
        raise SystemExit(f"bad command {command}")
    numbers = ", ".join(f"{float(a):.3f}" for a in args)
    return template.replace('"__COMMAND__"', json.dumps(command)).replace("--[[ARGS]]", numbers)


def result(raw: str) -> str:
    """The `result` field of an eval_*_runtime response (raises on Luau errors)."""
    data = json.loads(raw)
    if not data.get("ok", True):
        raise RuntimeError(raw[:500])
    value = data.get("result")
    return value if isinstance(value, str) else json.dumps(value)


def server(command: str, args: list[float] | None = None) -> str:
    return result(studio_mcp.call_tool("eval_server_runtime", {"code": render(SERVER, command, SERVER_COMMANDS, args or [])}))


def client(command: str, args: list[float] | None = None) -> str:
    return result(studio_mcp.call_tool("eval_client_runtime", {"code": render(CLIENT, command, CLIENT_COMMANDS, args or [])}))


def capture(path: Path) -> None:
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 86}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not images:
        raise RuntimeError("capture failed")
    path.write_bytes(base64.b64decode(images[0]["data"], validate=True))


def shoot(shot: dict, out: Path, prefix: str, settle: float) -> str:
    server("focus", shot["focus"])
    client("camera", [*shot["eye"], *shot["target"], shot.get("fov", 70)])
    time.sleep(settle)
    path = out / f"{prefix}{shot['name']}.jpg"
    capture(path)
    print(f"[tour] {path.name}", flush=True)
    return path.name


def sheet(out: Path, names: list[str], target: Path, cols: int = 4, width: int = 520) -> None:
    """Contact sheet (Pillow) of the given shots with labels."""
    from PIL import Image, ImageDraw

    images = [Image.open(out / n).convert("RGB") for n in names]
    if not images:
        return
    height = int(width * images[0].height / images[0].width)
    rows = (len(images) + cols - 1) // cols
    canvas = Image.new("RGB", (cols * width, rows * (height + 18)), (20, 22, 30))
    draw = ImageDraw.Draw(canvas)
    for i, (name, image) in enumerate(zip(names, images)):
        x, y = (i % cols) * width, (i // cols) * (height + 18)
        canvas.paste(image.resize((width, height)), (x, y + 18))
        draw.text((x + 5, y + 3), name, fill=(255, 255, 255))
    canvas.save(target, quality=85)


def zfight_pass(out: Path, settle: float, closeups: int = 6) -> dict:
    """Owner R18: live ZFight audit of the built world + close-ups of the first offenders."""
    report = json.loads(server("zfight"))
    (out / "zfight.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"[tour] zfight: {report['count']} offenders over {report['boxes']} boxes "
          f"({report['skippedRotated']} rotated parts skipped)", flush=True)
    names = []
    for index, offender in enumerate(report["offenders"][:closeups], start=1):
        centre, normal = offender["centre"], offender["normal"]  # world space
        # Look at the shared plane from 10 studs out along its normal, a little above and aside.
        eye = [centre[k] + normal[k] * 10 + (3 if k == 1 else 1.5) for k in range(3)]
        shot = {"name": f"zfight_{index:02d}", "eye": eye, "target": centre, "focus": centre, "fov": 55}
        names.append(shoot(shot, out, "", settle))
    if names:
        sheet(out, names, out / "sheet_zfight.jpg", cols=3)
    return {"count": report["count"], "closeups": names}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--out", type=Path)
    parser.add_argument("--only", choices=("full", "partial"))
    parser.add_argument("--settle", type=float, default=1.6, help="seconds between camera move and capture")
    parser.add_argument("--skip-lock", action="store_true")
    args = parser.parse_args()
    if not args.skip_lock:
        require_lock()
    out = args.out or ROOT / "docs/verification/world-qa" / datetime.now().strftime("%Y%m%d-%H%M")
    out.mkdir(parents=True, exist_ok=True)
    started = time.time()
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:120])
    record: dict = {"shots": {}, "log": []}
    try:
        time.sleep(4)
        record["log"].append(server("prepare"))
        client("hud_off")
        plan = {shot["name"]: shot for shot in json.loads(server("plan"))}
        if args.only in (None, "partial"):
            record["log"].append(server("partial"))
            names = [shoot(plan[n], out, "partial_", args.settle + 1.0 if i == 0 else args.settle)
                     for i, n in enumerate(PARTIAL_SHOTS)]
            record["shots"]["partial"] = names
            sheet(out, names, out / "sheet_partial.jpg", cols=3)
        if args.only in (None, "full"):
            record["log"].append(server("full"))
            order = ["hub_overview", "hub_ground", "plot_entrance"]
            order += [n for n in sorted(plan) if n.startswith("area")]
            order += ["plot_aerial", "ring_aerial"]
            names = [shoot(plan[n], out, "", args.settle + (1.5 if n in ("hub_overview", "plot_aerial", "ring_aerial") else 0))
                     for n in order]
            record["shots"]["full"] = names
            sheet(out, names, out / "sheet_full.jpg", cols=5, width=440)
            record["zfight"] = zfight_pass(out, args.settle)
    finally:
        try:
            client("hud_on")
            record["log"].append(server("restore"))
        except Exception as error:  # restore must not hide the original failure
            record["log"].append(f"restore failed: {error}")
        record["seconds"] = round(time.time() - started, 1)
        (out / "shots.json").write_text(json.dumps(record, indent=2) + "\n")
        stop_playtest()
    print(f"[tour] done in {record['seconds']} s -> {out}")
    for line in record["log"]:
        print(f"[tour] {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
