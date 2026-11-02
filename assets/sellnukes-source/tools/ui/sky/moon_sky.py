#!/usr/bin/env python3
"""
moon_sky.py — Moon Base's cartoon star-field SKYBOX (W9b, owner R70; spec
docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §2.2 "navy sky full of stars").

Why a skybox (not Lighting.ClockTime): the worlds client never touches ClockTime (the admin
SetTimeOfDay / day cycle own it), so stars from the night sky are impossible in a daytime place.
Instead WorldClientConfig.Lighting.moon.Sky names six Image assets; Client/Worlds/WorldClient parks
the place's Sky and shows a client-only "WorldSky" built from them while the player is on the Moon.
The sun keeps lighting the world, so the studs stay bright and readable (kid-friendly), but the sky
above is a friendly navy full of stars.

What it draws (deterministic: a fixed seed, so a rebuild without edits keeps every hash and nothing
re-uploads):
    * a vertical gradient by TRUE elevation (zenith navy -> soft violet horizon glow -> lilac below);
      computed from each pixel's 3-D direction, so the four side faces meet seamlessly whatever
      their order, and the Up / Dn faces are rotation-proof (radially symmetric)
    * ~900 stars per side face (fading toward the horizon) and ~1,400 on the Up face, sizes
      0.6-2.2 px, white / butter / ice-blue / pink, the brightest with a four-point twinkle
    * two or three soft nebula puffs per face (pink / violet / teal, alpha <= 0.22)
    Stars and puffs keep a margin from every face edge, so nothing is ever cut at a seam.

Commands:
    python3 tools/ui/sky/moon_sky.py build                      # PNGs + sky.json (sha256 per face)
    python3 tools/ui/sky/moon_sky.py upload --user-id 1586034782 # Image assets (journal + receipts)
    python3 tools/ui/sky/moon_sky.py luau                       # prints the WorldClientConfig Sky block

Upload safety (same as tools/ui/icons/icons.py): the journal is written BEFORE each POST and with the
operation path BEFORE polling; a face whose receipt sha256 matches the PNG is never re-uploaded; a
POST whose outcome is unknown blocks an automatic duplicate. The Open Cloud key is read by
tools/ui/icons/opencloud.py (env / private key file), never printed.

Outputs: assets/sky/moon/{SkyboxBk,SkyboxDn,SkyboxFt,SkyboxLf,SkyboxRt,SkyboxUp}.png, sky.json,
journal/<face>.json, receipts/<face>.json.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "assets" / "sky" / "moon"
JOURNAL = OUT / "journal"
RECEIPTS = OUT / "receipts"
sys.path.insert(0, str(ROOT / "tools" / "ui" / "icons"))

SIZE = 1024
SEED = 70_031  # R70 (change it and every face re-uploads)
FACES = ("SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp")
MARGIN = 0.035  # fraction of the face kept free of stars / puffs at every edge (no cut seams)

# Gradient stops by elevation in degrees (kid-friendly: navy, never black).
STOPS = (
    (-90.0, (70, 62, 140)),
    (-8.0, (92, 80, 170)),
    (0.0, (118, 100, 204)),  # soft violet horizon glow
    (14.0, (58, 58, 148)),
    (45.0, (38, 44, 118)),
    (90.0, (26, 32, 90)),
)
STAR_COLORS = ((255, 255, 255), (255, 244, 196), (200, 232, 255), (255, 210, 236))
PUFF_COLORS = ((255, 140, 210), (170, 120, 255), (110, 230, 230))


def _directions(face: str):
    """Per-pixel unit directions (H x W x 3) of a cube face; side faces are upright (+Y = up)."""
    t = (np.arange(SIZE) + 0.5) / SIZE * 2.0 - 1.0
    u, v = np.meshgrid(t, -t)  # u right, v up
    one = np.ones_like(u)
    if face == "SkyboxUp":
        d = np.stack([u, one, -v], axis=-1)
    elif face == "SkyboxDn":
        d = np.stack([u, -one, v], axis=-1)
    else:
        # The four side faces share the same (horizontal offset, up) parametrisation; which compass
        # side each one is does not matter to an elevation gradient.
        d = np.stack([u, v, one], axis=-1)
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


def _gradient(elevation_deg):
    """RGB float image from an elevation map (degrees) through the STOPS."""
    out = np.zeros(elevation_deg.shape + (3,), dtype=np.float64)
    xs = [s[0] for s in STOPS]
    for c in range(3):
        out[..., c] = np.interp(elevation_deg, xs, [s[1][c] for s in STOPS])
    return out


def _edge_falloff():
    """1 inside the face, smoothly 0 at the borders (keeps puffs off the seams)."""
    t = (np.arange(SIZE) + 0.5) / SIZE
    edge = np.minimum(t, 1.0 - t)
    ramp = np.clip((edge - MARGIN) / 0.12, 0.0, 1.0)
    ramp = ramp * ramp * (3 - 2 * ramp)
    return np.outer(ramp, ramp)


def _splat(img, cx, cy, radius, color, alpha):
    """Adds a soft round dot (gaussian core) to img (float RGB) in place."""
    r = int(math.ceil(radius * 3.0)) + 1
    x0, x1 = max(0, int(cx) - r), min(SIZE, int(cx) + r + 1)
    y0, y1 = max(0, int(cy) - r), min(SIZE, int(cy) + r + 1)
    if x0 >= x1 or y0 >= y1:
        return
    ys, xs = np.mgrid[y0:y1, x0:x1]
    d2 = (xs + 0.5 - cx) ** 2 + (ys + 0.5 - cy) ** 2
    a = alpha * np.exp(-d2 / (2.0 * radius * radius))
    for c in range(3):
        img[y0:y1, x0:x1, c] += (color[c] - img[y0:y1, x0:x1, c]) * a


def _twinkle(img, cx, cy, length, color):
    """A four-point twinkle (thin horizontal + vertical streaks) through a bright star."""
    for dx, dy in ((1, 0), (0, 1)):
        for k in range(-int(length), int(length) + 1):
            fall = 1.0 - abs(k) / (length + 1.0)
            _splat(img, cx + dx * k, cy + dy * k, 0.55, color, 0.55 * fall * fall)


def build_face(face: str, index: int):
    """Renders one face (uint8 RGB array)."""
    rng = np.random.default_rng(SEED + index * 101)
    d = _directions(face)
    elevation = np.degrees(np.arcsin(np.clip(d[..., 1], -1.0, 1.0)))
    img = _gradient(elevation)
    falloff = _edge_falloff()
    if face != "SkyboxDn":
        # Nebula puffs (soft, low alpha, faded at the edges).
        for _ in range(int(rng.integers(2, 4))):
            cx, cy = rng.uniform(0.25, 0.75) * SIZE, rng.uniform(0.15 if face == "SkyboxUp" else 0.1, 0.55) * SIZE
            rx, ry = rng.uniform(120, 220), rng.uniform(70, 140)
            color = np.array(PUFF_COLORS[int(rng.integers(0, len(PUFF_COLORS)))], dtype=np.float64)
            ys, xs = np.mgrid[0:SIZE, 0:SIZE]
            a = 0.22 * np.exp(-(((xs - cx) / rx) ** 2 + ((ys - cy) / ry) ** 2)) * falloff
            img += (color - img) * a[..., None]
        # Stars: more overhead, fading out toward the horizon.
        count = 1400 if face == "SkyboxUp" else 900
        lo, hi = MARGIN * SIZE, (1.0 - MARGIN) * SIZE
        for _ in range(count):
            x, y = rng.uniform(lo, hi), rng.uniform(lo, hi)
            elev = elevation[int(y), int(x)]
            if elev < 2.0:
                continue
            fade = min(1.0, (elev - 2.0) / 16.0)
            big = rng.random() < 0.06
            radius = rng.uniform(1.3, 2.2) if big else rng.uniform(0.6, 1.2)
            color = STAR_COLORS[int(rng.integers(0, len(STAR_COLORS)))]
            _splat(img, x, y, radius, color, min(1.0, (0.95 if big else rng.uniform(0.45, 0.9)) * fade))
            if big and fade > 0.6:
                _twinkle(img, x, y, rng.uniform(5.0, 9.0), color)
    return np.clip(img, 0, 255).astype(np.uint8)


def _png_bytes(arr) -> bytes:
    """Deterministic PNG bytes (no metadata, fixed compression)."""
    buf = io.BytesIO()
    Image.fromarray(arr, "RGB").save(buf, format="PNG", optimize=False, compress_level=9)
    return buf.getvalue()


def _atomic_json(path: Path, data: dict) -> None:
    """Writes JSON through a temp file + rename (never a half-written journal / receipt)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-", suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
    os.replace(tmp, path)


def command_build(_args) -> int:
    """Renders the six faces into assets/sky/moon + sky.json (sha256 per face)."""
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {"seed": SEED, "size": SIZE, "faces": {}}
    for i, face in enumerate(FACES):
        data = _png_bytes(build_face(face, i))
        (OUT / f"{face}.png").write_bytes(data)
        manifest["faces"][face] = hashlib.sha256(data).hexdigest()
        print(f"[sky] {face}.png {len(data) // 1024} KB")
    _atomic_json(OUT / "sky.json", manifest)
    return 0


def command_upload(args) -> int:
    """Uploads every face whose PNG has no matching receipt (one Image asset per face)."""
    import opencloud  # noqa: E402  (repo-local, stdlib-only Open Cloud client)

    manifest = json.loads((OUT / "sky.json").read_text())
    if not str(args.user_id).isdigit():
        raise SystemExit("--user-id must be numeric")
    client = opencloud.Client(opencloud.read_key())
    creator = {"userId": str(args.user_id)}
    for face in FACES:
        data = (OUT / f"{face}.png").read_bytes()
        sha = hashlib.sha256(data).hexdigest()
        if sha != manifest["faces"][face]:
            raise SystemExit(f"{face}.png does not match sky.json; rerun build")
        receipt_path, journal_path = RECEIPTS / f"{face}.json", JOURNAL / f"{face}.json"
        receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
        if receipt.get("sha256") == sha and receipt.get("assetId"):
            print(f"[sky] {face}: up to date ({receipt['assetId']})")
            continue
        entry = json.loads(journal_path.read_text()) if journal_path.exists() else {}
        if entry and entry.get("sha256") != sha:
            raise SystemExit(f"{face}: journal is for another picture; reconcile, then remove journal/{face}.json")
        if entry.get("status") == "submitting":
            raise SystemExit(f"{face}: prior POST outcome unknown; check Creator Dashboard, then remove journal/{face}.json")
        if not entry:
            entry = {"sha256": sha, "status": "submitting"}
            _atomic_json(journal_path, entry)
            response = client.create_image(
                f"SellNukes Moon sky {face}",
                "Moon Base star-field skybox face (SellNukes, owner R70).",
                data,
                f"moon-{face}.png",
                creator,
            )
            operation = response.get("path")
            if not isinstance(operation, str) or not operation.startswith("operations/"):
                raise SystemExit(f"{face}: unknown POST outcome; reconcile before retrying")
            entry.update(status="pending", operation=operation)
            _atomic_json(journal_path, entry)
        deadline = time.monotonic() + 180
        while entry.get("status") == "pending":
            response = client.poll(entry["operation"])
            if response.get("done") is True:
                asset = response.get("response", {})
                asset_id = asset.get("assetId") if isinstance(asset, dict) else None
                if response.get("error") or not str(asset_id).isdigit():
                    entry["status"] = "failed"
                    _atomic_json(journal_path, entry)
                    raise SystemExit(f"{face}: asset operation failed; reconcile before creating another asset")
                entry.update(status="complete", assetId=int(asset_id))
                _atomic_json(journal_path, entry)
            elif time.monotonic() >= deadline:
                raise SystemExit(f"{face}: polling timed out; rerun upload to resume")
            else:
                time.sleep(3)
        _atomic_json(receipt_path, {"sha256": sha, "assetId": entry["assetId"]})
        print(f"[sky] {face}: Image asset {entry['assetId']}")
    return 0


def command_luau(_args) -> int:
    """Prints the WorldClientConfig Sky block from the receipts."""
    lines = []
    for face in FACES:
        receipt_path = RECEIPTS / f"{face}.json"
        asset = json.loads(receipt_path.read_text()).get("assetId") if receipt_path.exists() else None
        lines.append(f'\t\t\t{face} = "{"rbxassetid://" + str(asset) if asset else ""}",')
    print("\n".join(lines))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build")
    up = sub.add_parser("upload")
    up.add_argument("--user-id", required=True)
    sub.add_parser("luau")
    args = parser.parse_args()
    return {"build": command_build, "upload": command_upload, "luau": command_luau}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
