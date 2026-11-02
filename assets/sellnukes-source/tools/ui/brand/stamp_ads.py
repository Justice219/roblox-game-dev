#!/usr/bin/env python3
"""
stamp_ads.py — stamps the SELL NUKES title onto the ad creatives (owner R66).

Why: the owner wants the game's logo on every ad. The logo is the exact in-game title
(`assets/brand/logo-text.png`, ForgeGUI R38), composited locally so it is pixel-identical across
all ads and the ad art itself is never regenerated.

How:
    * Sources are the un-logo'd finals in `assets/marketing/2026-10-30-ads/history/no-logo/`
      (copied there on the first run, so re-running never stamps a logo twice).
    * The logo is scaled to LOGO_WIDTH of the ad width, given a soft drop shadow (blurred alpha,
      offset down-right) so it reads on bright skies and busy scenes alike, and placed in the corner
      chosen per ad in CORNERS (picked by eye so it never covers a face or the hook text).
    * Output overwrites `final/<ad>.png` (1920 x 1080 PNG, opaque).

Usage:
    python3 tools/ui/brand/stamp_ads.py            # stamp every ad in CORNERS
    python3 tools/ui/brand/stamp_ads.py --sheet S  # also write a review contact sheet to S
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[3]
ADS = ROOT / "assets/marketing/2026-10-30-ads"
FINAL = ADS / "final"
SOURCE = ADS / "history/no-logo"
LOGO = ROOT / "assets/brand/logo-text.png"

LOGO_WIDTH = 0.30  # fraction of the ad width
MARGIN = 0.025  # fraction of the ad width, from the chosen corner
SHADOW_OFFSET = (8, 10)  # px down-right at 1920 wide
SHADOW_BLUR = 10
SHADOW_ALPHA = 0.55

# ad file stem -> spot ("tl", "tr", "bl", "br", or "bc" = bottom-centre for split NOOB-vs-PRO
# layouts that have no free corner), chosen so the logo avoids faces + hook text.
CORNERS = {
    "ad01-can-you-reach-1-billion": "bl",
    "ad02-start-with-1-click": "tl",
    "ad03-earn-while-you-sleep": "tr",
    "ad04-beat-your-friends": "tl",
    "ad05-upgrade-x2-cash": "tr",
    "ad06-harvest-feast-event": "tr",
    "ad07-aa-tower-vs-100-nukes": "br",
    "ad08-hatch-a-secret-pet": "bl",
    "ad09-garage-to-nuke-empire": "tl",
    "ad10-step-on-it-watch-it-build": "tr",
    # R68: three more creatives (masters written straight into history/no-logo/).
    "ad11-dino-valley": "tl",
    "ad12-knockdown": "tl",
    "ad13-noob-vs-pro-dino": "bc",
}
# Optional per-ad logo width (fraction of the ad width) where the default would crowd the scene.
WIDTHS = {"ad13-noob-vs-pro-dino": 0.22}


def stamp(ad: Image.Image, logo: Image.Image, corner: str, logo_width: float = LOGO_WIDTH) -> Image.Image:
    """Returns `ad` (RGB) with `logo` (RGBA) + soft shadow composited at `corner` (see CORNERS)."""
    width, height = ad.size
    target_w = round(width * logo_width)
    target_h = round(logo.height * target_w / logo.width)
    mark = logo.convert("RGBa").resize((target_w, target_h), Image.Resampling.LANCZOS).convert("RGBA")
    margin = round(width * MARGIN)
    if corner == "bc":
        x = (width - target_w) // 2
    else:
        x = margin if corner in ("tl", "bl") else width - margin - target_w
    y = margin if corner in ("tl", "tr") else height - margin - target_h
    base = ad.convert("RGBA")
    shadow_alpha = mark.getchannel("A").point(lambda a: int(a * SHADOW_ALPHA)).filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    shadow = Image.new("RGBA", mark.size, (0, 0, 0, 0))
    shadow.putalpha(shadow_alpha)
    base.alpha_composite(shadow, (x + SHADOW_OFFSET[0], y + SHADOW_OFFSET[1]))
    base.alpha_composite(mark, (x, y))
    return base.convert("RGB")


def main() -> int:
    parser = argparse.ArgumentParser(description="Stamp the SELL NUKES logo onto the ads (R66).")
    parser.add_argument("--sheet", help="also write a review contact sheet (JPEG) to this path")
    args = parser.parse_args()
    SOURCE.mkdir(parents=True, exist_ok=True)
    logo = Image.open(LOGO).convert("RGBA")
    stamped = []
    for stem, corner in CORNERS.items():
        src = SOURCE / f"{stem}.png"
        if not src.exists():
            shutil.copy2(FINAL / f"{stem}.png", src)  # first run: keep the un-logo'd original
        out = stamp(Image.open(src), logo, corner, WIDTHS.get(stem, LOGO_WIDTH))
        out.save(FINAL / f"{stem}.png", optimize=True)
        stamped.append(out)
        print(f"  {stem}: logo {corner}")
    if args.sheet:
        w, h = 480, 270
        sheet = Image.new("RGB", (w * 2, h * ((len(stamped) + 1) // 2)), "black")
        for i, im in enumerate(stamped):
            sheet.paste(im.resize((w, h)), ((i % 2) * w, (i // 2) * h))
        sheet.save(args.sheet, quality=82)
        print(f"  sheet -> {args.sheet}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
