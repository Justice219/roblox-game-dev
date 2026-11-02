#!/usr/bin/env python3
"""
contact_sheet.py — tile Blender previews into one labelled image for quick art review.

Reads assets/blender/previews/<Key>_<view>.jpg (written by generate_world.py) and writes
assets/blender/previews/_sheet_<view>.jpg (or --out). Pure Pillow; runs on the system python3.

Usage:
    python3 tools/blender/contact_sheet.py [--view iso|front] [--only BuyPad,PocketNuke] [--cols 4]
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
PREVIEWS = ROOT / "assets/blender/previews"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--view", default="iso", choices=("iso", "front"))
    parser.add_argument("--only", default="")
    parser.add_argument("--cols", type=int, default=4)
    parser.add_argument("--cell", type=int, default=360, help="cell width in px")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    wanted = [k for k in args.only.split(",") if k]
    files = sorted(PREVIEWS.glob(f"*_{args.view}.jpg"))
    files = [f for f in files if not wanted or f.name[: -len(f"_{args.view}.jpg")] in wanted]
    if not files:
        raise SystemExit("no previews found; run generate_world.py first")
    cell_w = args.cell
    cell_h = int(cell_w * 0.8) + 22
    cols = max(1, min(args.cols, len(files)))
    rows = (len(files) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell_w, rows * cell_h), (30, 32, 40))
    draw = ImageDraw.Draw(sheet)
    for i, path in enumerate(files):
        img = Image.open(path).convert("RGB")
        img.thumbnail((cell_w, cell_h - 22))
        x, y = (i % cols) * cell_w, (i // cols) * cell_h
        sheet.paste(img, (x, y + 22))
        draw.text((x + 6, y + 5), path.name[: -len(f"_{args.view}.jpg")], fill=(255, 255, 255))
    out = args.out or PREVIEWS / f"_sheet_{args.view}.jpg"
    sheet.save(out, quality=88)
    print(f"[sheet] {len(files)} previews -> {out}")


if __name__ == "__main__":
    main()
