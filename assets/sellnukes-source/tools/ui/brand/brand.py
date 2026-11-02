#!/usr/bin/env python3
"""Render, compose, upload and map the SellNukes in-game brand art (logo, Nukey, loading key art).

Brand package (lead, 2026-10-30):
    1. "SELL NUKES" logo: chunky stud letters, candy colours, Nukey + a radiation-trefoil accent,
       thick dark outline, transparent PNG, 2048 wide        -> assets/brand/logo.png
    2. Nukey mascot + the hub key art (loading-screen backdrop, staged from B4's real models).
    3. Loading-screen art uploaded as Image assets (logo, Nukey, key art) and mapped into
       src/shared/Config/BrandAssets.luau + src/first/LoadingScreen/BrandImages.luau.

Pipeline (deterministic):
    render   Blender raw passes (tools/blender/ui_icons/render_brand.py) -> assets/brand/raw/
    compose  outline + sizes + composition + captions (Pillow, Luckiest Guy font, pinned)
    title    adopts the ForgeGUI title master (assets/brand/logo-forgegui.png, owner R38) as the
             in-game "SELL NUKES" title: logo-text.png + logo-text-1024.png (compose does the same)
    upload   Open Cloud Image assets for the in-game art (journal before POST, receipts with
             sha256, unchanged files skipped, changed ones need --replace), then `sync`
    sync     writes BrandAssets.luau + BrandImages.luau (GENERATED) from receipts
    open     opens the brand files in Preview (owner R12)
    all      render + compose + open (no upload)

Store thumbnails + the experience icon are NOT made here any more (owner R23): the lead makes them
with ForgeGUI in assets/marketing/2026-10-30-forgegui/ (see docs/brand.md).

Usage:
    python3 tools/ui/brand/brand.py render [--only Logo,Hub]
    python3 tools/ui/brand/brand.py compose
    python3 tools/ui/brand/brand.py title
    python3 tools/ui/brand/brand.py upload --user-id 1586034782 [--replace Logo]
    python3 tools/ui/brand/brand.py sync | open | status
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
BRAND = ROOT / "assets/brand"
RAW = BRAND / "raw"
RECEIPTS = BRAND / "receipts"
JOURNALS = BRAND / "journal"
HISTORY = BRAND / "history"
FONT = BRAND / "fonts/LuckiestGuy-Regular.ttf"
FONT_SHA256 = "cfbdd68a039f92df51cf3721506af6242e64594c6325fe0bedbeff3fe385d980"
WORLD = ROOT / "assets/blender/world"
BLENDER_SCRIPT = ROOT / "tools/blender/ui_icons/render_brand.py"
BRAND_LUAU = ROOT / "src/shared/Config/BrandAssets.luau"
FIRST_LUAU = ROOT / "src/first/LoadingScreen/BrandImages.luau"
PANEL_LUAU = ROOT / "src/shared/Config/PanelTextureAssets.luau"
RENDERS = ("Logo", "LogoText", "Nukey", "Hub")
# Owner R38: the in-game title is the ForgeGUI "SELL NUKES" lettering (Sell Lemons-style stacked
# chunky glossy stud letters, no "$"). When this master exists it replaces the Blender LogoText pass.
TITLE_MASTER = BRAND / "logo-forgegui.png"
TITLE_PAD_PX = 16  # transparent margin kept around the trimmed lettering (master pixels)
OUTLINE_RGB = (20, 20, 28)  # UIStyleConfig.TextStroke, same as every icon

# Files shipped in game as Image assets: key -> (file, displayed size, purpose).
UPLOADS = {
    "Logo": ("logo-text-1024.png", "the SELL NUKES title, text only (loading screen, title cards)"),
    "Nukey": ("nukey-1024.png", "the Nukey mascot (loading screen)"),
    "KeyArt": ("keyart-1024.png", "the hub key art (loading-screen backdrop)"),
}
ASSET_ID = re.compile(r"[1-9][0-9]{0,18}\Z")


class BrandError(Exception):
    """A user-facing failure (never contains credentials or request bodies)."""


def load_module(name: str, path: Path):
    """Our own sibling tooling, loaded by path (icons.py helpers, opencloud.py transport)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def icons():
    """tools/ui/icons/icons.py (dilate / over / atomic writes)."""
    return load_module("sn_icons", ROOT / "tools/ui/icons/icons.py")


def font(size: int):
    """The pinned Luckiest Guy font (Apache-2.0) at `size` px; refuses a modified file."""
    from PIL import ImageFont

    data = FONT.read_bytes()
    if hashlib.sha256(data).hexdigest() != FONT_SHA256:
        raise BrandError("assets/brand/fonts/LuckiestGuy-Regular.ttf does not match its pinned sha256")
    return ImageFont.truetype(io.BytesIO(data), size)


def save_png(image, path: Path) -> None:
    """Optimised PNG, written atomically."""
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    icons().atomic_write(path, buffer.getvalue())
    print(f"  wrote {path.relative_to(ROOT)} {image.size[0]}x{image.size[1]} ({len(buffer.getvalue()) // 1024} KB)")


# =============================================================================================
# render
# =============================================================================================


def command_render(args) -> int:
    """Blender raw passes for the selected renders (one process)."""
    names = [n.strip() for n in args.only.split(",")] if args.only else list(RENDERS)
    for name in names:
        if name not in RENDERS:
            raise BrandError(f"unknown render {name!r}")
    blender = os.environ.get("BLENDER") or shutil.which("blender")
    if not blender:
        raise BrandError("Blender not found: put it on PATH or set $BLENDER")
    RAW.mkdir(parents=True, exist_ok=True)
    font(10)  # verify the pin before Blender loads the file
    subprocess.run(
        [blender, "--background", "--factory-startup", "--python-exit-code", "1", "--python", str(BLENDER_SCRIPT), "--", str(RAW), str(FONT), str(WORLD), *names],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    print(f"Rendered {', '.join(names)} -> {RAW.relative_to(ROOT)}")
    return 0


# =============================================================================================
# compose
# =============================================================================================


def outlined(raw, outline_px: int, pad_px: int):
    """
    A transparent render trimmed to its art, given a thick dark outer outline (exact disc
    dilation, `outline_px` raw px) and `pad_px` transparent margin. Same look as the icons.
    """
    import numpy as np
    from PIL import Image

    module = icons()
    art = module.trimmed(raw.convert("RGBA"))
    margin = outline_px + pad_px
    canvas = Image.new("RGBA", (art.width + 2 * margin, art.height + 2 * margin), (0, 0, 0, 0))
    canvas.alpha_composite(art, (margin, margin))
    pixels = np.asarray(canvas, dtype=np.float64) / 255.0
    line = np.zeros_like(pixels)
    line[..., :3] = np.array(OUTLINE_RGB, dtype=np.float64) / 255.0
    line[..., 3] = module.dilate(pixels[..., 3] > 0.5, outline_px)
    merged = module.over(line, pixels)
    return Image.fromarray(np.clip(np.round(merged * 255), 0, 255).astype(np.uint8), "RGBA")


def resized(image, width: int | None = None, height: int | None = None):
    """Premultiplied Lanczos resize (no dark fringes on transparent edges), keeping aspect."""
    from PIL import Image

    if width is None:
        width = round(image.width * height / image.height)
    if height is None:
        height = round(image.height * width / image.width)
    return image.convert("RGBa").resize((width, height), Image.Resampling.LANCZOS).convert("RGBA")


def graded(image, saturation=1.22, contrast=1.08, brightness=1.02):
    """The key art's toy-bright grade (Standard-view EEVEE renders are a little soft)."""
    from PIL import ImageEnhance

    image = ImageEnhance.Color(image).enhance(saturation)
    image = ImageEnhance.Contrast(image).enhance(contrast)
    return ImageEnhance.Brightness(image).enhance(brightness)


def compose_title() -> None:
    """
    Writes the in-game title (logo-text.png + logo-text-1024.png, text only, no Nukey).

    Source: the ForgeGUI master (TITLE_MASTER, owner R38) when present — it already carries its
    own thick navy outline, so it is only trimmed to its alpha bounds and padded; never upscaled
    (logo-text.png stays at the master's native width, capped at 2048). Otherwise the Blender
    LogoText pass, outlined like every icon.
    Example: `brand.py title` after saving a new pick as assets/brand/logo-forgegui.png.
    """
    from PIL import Image

    if TITLE_MASTER.is_file():
        with Image.open(TITLE_MASTER) as opened:
            art = icons().trimmed(opened.convert("RGBA"))
        title = Image.new("RGBA", (art.width + 2 * TITLE_PAD_PX, art.height + 2 * TITLE_PAD_PX), (0, 0, 0, 0))
        title.alpha_composite(art, (TITLE_PAD_PX, TITLE_PAD_PX))
        full = resized(title, width=2048) if title.width > 2048 else title
    else:
        if not (RAW / "LogoText.png").is_file():
            raise BrandError("raw/LogoText.png missing: run `render` first (or add logo-forgegui.png)")
        with Image.open(RAW / "LogoText.png") as opened:
            title = outlined(opened, 52, 16)
        full = resized(title, width=2048)
    save_png(full, BRAND / "logo-text.png")
    save_png(resized(title, width=1024), BRAND / "logo-text-1024.png")


def command_title(_args=None) -> int:
    """Rebuilds only the in-game title files (see compose_title)."""
    compose_title()
    return 0


def command_compose(_args=None) -> int:
    """Builds every brand file from the raw passes."""
    from PIL import Image

    for name in RENDERS:
        if not (RAW / f"{name}.png").is_file():
            raise BrandError(f"raw/{name}.png missing: run `render` first")
    BRAND.mkdir(parents=True, exist_ok=True)
    # 1. Logo: outline at the raw 4096 scale (52 raw px = 26 px at 2048), then 2048 + 1024 wide.
    with Image.open(RAW / "Logo.png") as opened:
        logo_raw = outlined(opened, 52, 16)
    logo = resized(logo_raw, width=2048)
    save_png(logo, BRAND / "logo.png")
    # Text-only title (no Nukey): the in-game title next to the loading screen's own Nukey.
    compose_title()
    # 2. Nukey: outlined mascot (2048 raw -> 1024).
    with Image.open(RAW / "Nukey.png") as opened:
        nukey_raw = outlined(opened, 40, 12)
    nukey = resized(nukey_raw, height=1024) if nukey_raw.height >= nukey_raw.width else resized(nukey_raw, width=1024)
    save_png(nukey, BRAND / "nukey-1024.png")
    # 3. Loading-screen key art (hub), 1024 x 576, toy-bright grade, no text (the screen adds its own).
    with Image.open(RAW / "Hub.png") as opened:
        art = graded(opened.convert("RGB").resize((1024, 576), Image.Resampling.LANCZOS))
    save_png(art, BRAND / "keyart-1024.png")
    return 0


# =============================================================================================
# upload (journaled, idempotent) + sync
# =============================================================================================


def read_json(path: Path, missing=None):
    """A JSON object from a regular file (or `missing`)."""
    if not path.exists():
        return missing
    if path.is_symlink() or not path.is_file():
        raise BrandError(f"{path.name} must be a regular file")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise BrandError(f"{path.name} must hold an object")
    return value


def write_json(path: Path, value) -> None:
    """Deterministic JSON, atomically."""
    path.parent.mkdir(parents=True, exist_ok=True)
    icons().atomic_write(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def upload_one(client, name: str, data: bytes, identity: dict, description: str) -> dict:
    """
    One Image asset: journal BEFORE the POST ("submitting"), operation path before polling
    ("pending"), receipt after. An ambiguous POST is never retried automatically.
    """
    journal_path, receipt_path = JOURNALS / f"{name}.json", RECEIPTS / f"{name}.json"
    entry = read_json(journal_path, {})
    if entry and any(entry.get(k) != v for k, v in identity.items()):
        raise BrandError(f"{name}: journaled identity differs; reconcile, then --replace {name}")
    if entry.get("status") == "submitting":
        raise BrandError(f"{name}: previous POST outcome unknown; check Creator Dashboard, then delete journal/{name}.json")
    if not entry:
        entry = {**identity, "status": "submitting"}
        write_json(journal_path, entry)
        response = client.create_image(f"SellNukes brand {name}", description, data, f"brand-{name}.png", identity["creator"])
        operation = response.get("path")
        if not isinstance(operation, str) or not re.fullmatch(r"operations/[A-Za-z0-9_-]{1,200}", operation):
            raise BrandError(f"{name}: unknown POST outcome; reconcile before retrying")
        entry.update(status="pending", operation=operation)
        write_json(journal_path, entry)
    deadline = time.monotonic() + 180
    while entry.get("status") == "pending":
        response = client.poll(entry["operation"])
        if response.get("done") is True:
            asset = response.get("response", {})
            asset_id = asset.get("assetId") if isinstance(asset, dict) else None
            if response.get("error") or not ASSET_ID.fullmatch(str(asset_id)):
                entry["status"] = "failed"
                write_json(journal_path, entry)
                raise BrandError(f"{name}: asset operation failed")
            moderation = asset.get("moderationResult", {})
            entry.update(status="complete", assetId=int(asset_id), moderation=str(moderation.get("moderationState", "unknown") if isinstance(moderation, dict) else "unknown")[:32])
            write_json(journal_path, entry)
        elif time.monotonic() > deadline:
            raise BrandError(f"{name}: polling timed out; rerun upload to resume")
        else:
            time.sleep(3)
    receipt = {**identity, "assetId": entry["assetId"], "moderation": entry.get("moderation", "unknown")}
    write_json(receipt_path, receipt)
    return receipt


def command_upload(args) -> int:
    """Uploads changed in-game brand images (logo, Nukey, key art), then syncs the Luau maps."""
    if args.user_id <= 0:
        raise BrandError("User ID must be positive")
    cloud = load_module("sn_opencloud", ROOT / "tools/ui/icons/opencloud.py")
    replace = {n.strip() for n in args.replace.split(",")} if args.replace else set()
    creator = {"userId": str(args.user_id)}
    plan = []
    for name, (file, purpose) in UPLOADS.items():
        data = (BRAND / file).read_bytes()
        if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) > 20_000_000:
            raise BrandError(f"{file} is not a PNG within limits")
        identity = {"name": name, "sha256": hashlib.sha256(data).hexdigest(), "creator": creator, "assetType": "Image"}
        receipt = read_json(RECEIPTS / f"{name}.json", {})
        if receipt and all(receipt.get(k) == v for k, v in identity.items()):
            continue
        if receipt and name not in replace:
            raise BrandError(f"{name}: a different picture is already uploaded; pass --replace {name}")
        plan.append((name, data, identity, purpose))
    if not plan:
        print("Nothing to upload.")
        return command_sync()
    try:
        client = cloud.Client(cloud.read_key())
        for name, data, identity, purpose in plan:
            if name in replace:
                old = read_json(RECEIPTS / f"{name}.json", {})
                if old:
                    folder = HISTORY / name / str(old.get("sha256", "x"))[:12]
                    folder.mkdir(parents=True, exist_ok=True)
                    for path in (RECEIPTS / f"{name}.json", JOURNALS / f"{name}.json"):
                        if path.is_file():
                            os.replace(path, folder / path.name)
            receipt = upload_one(client, name, data, identity, f"SellNukes brand art: {purpose}. Original artwork; title font Luckiest Guy (Apache-2.0).")
            print(f"  {name}: Image asset {receipt['assetId']} ({receipt['moderation']})")
            time.sleep(1)
    except cloud.CloudError as error:
        raise BrandError(str(error)) from None
    return command_sync()


def command_moderation(_args=None) -> int:
    """Refreshes the receipts' moderation states (read-only), then syncs."""
    cloud = load_module("sn_opencloud", ROOT / "tools/ui/icons/opencloud.py")
    try:
        client = cloud.Client(cloud.read_key())
        for name in UPLOADS:
            path = RECEIPTS / f"{name}.json"
            receipt = read_json(path, {})
            if isinstance(receipt.get("assetId"), int):
                state = client.moderation(receipt["assetId"])
                if state != receipt.get("moderation"):
                    receipt["moderation"] = state
                    write_json(path, receipt)
                print(f"  {name}: {receipt['assetId']} {state}")
    except cloud.CloudError as error:
        raise BrandError(str(error)) from None
    return command_sync()


def asset_ids() -> dict[str, int]:
    """Uploaded id per brand image (0 = none, stale or Rejected)."""
    ids = {}
    for name, (file, _) in UPLOADS.items():
        receipt = read_json(RECEIPTS / f"{name}.json", {})
        current = BRAND / file
        sha = hashlib.sha256(current.read_bytes()).hexdigest() if current.is_file() else None
        ok = isinstance(receipt.get("assetId"), int) and receipt.get("sha256") == sha and str(receipt.get("moderation", "")).lower() != "rejected"
        ids[name] = receipt["assetId"] if ok else 0
    return ids


def panel_stud_id() -> int:
    """The uploaded stud panel texture id from PanelTextureAssets.luau (0 when not found)."""
    match = re.search(r"AssetId = (\d+),", PANEL_LUAU.read_text(encoding="utf-8")) if PANEL_LUAU.is_file() else None
    return int(match.group(1)) if match else 0


def image_sizes() -> dict[str, tuple[int, int]]:
    """Pixel size of each uploaded brand image (for aspect-correct UI)."""
    from PIL import Image

    sizes = {}
    for name, (file, _) in UPLOADS.items():
        path = BRAND / file
        if path.is_file():
            with Image.open(path) as opened:
                sizes[name] = opened.size
        else:
            sizes[name] = (1, 1)
    return sizes


def command_sync(_args=None) -> int:
    """Writes the GENERATED Luau maps (shared BrandAssets + the ReplicatedFirst copy), StyLua-clean."""
    ids, sizes, stud = asset_ids(), image_sizes(), panel_stud_id()
    entries = []
    for name in UPLOADS:
        width, height = sizes[name]
        image = f'"rbxassetid://{ids[name]}"' if ids[name] else '""'
        entries.append(f"\t{name} = table.freeze({{ image = {image}, size = Vector2.new({width}, {height}) }}),")
    stud_image = f'"rbxassetid://{stud}"' if stud else '""'
    body = "\n".join(entries)
    shared = f'''--!strict
--[[
	BrandAssets — GENERATED by tools/ui/brand/brand.py (sync). Do not edit by hand.

	Purpose:
		The uploaded SellNukes brand images: the "SELL NUKES" logo, the Nukey mascot and the hub
		key art (loading screen, title cards, shop headers). image "" = not uploaded yet / rejected:
		show a text fallback. Masters (2048 logo, text logo, Nukey, key art):
		assets/brand/ (runbook: docs/brand.md). ReplicatedFirst has its own copy of these ids
		(src/first/LoadingScreen/BrandImages.luau) because Shared has not replicated at first paint.

	Example:
		local logo = BrandAssets.Images.Logo
		label.Image = logo.image -- "" until uploaded
		label.Size = UDim2.fromOffset(400, 400 * logo.size.Y / logo.size.X)
]]

export type BrandImage = {{ read image: string, read size: Vector2 }}

local BrandAssets = {{}}

-- Uploaded brand images (size = the uploaded PNG's pixel size, for aspect-correct layout).
BrandAssets.Images = table.freeze({{
{body}
}}) :: {{ [string]: BrandImage }}

-- The stud panel texture (PanelTextureAssets) the loading screen tiles behind everything.
BrandAssets.StudTexture = {stud_image}

return table.freeze(BrandAssets)
'''
    first = f'''--!strict
--[[
	BrandImages — GENERATED by tools/ui/brand/brand.py (sync). Do not edit by hand.

	The loading screen's own copy of the brand image ids (ReplicatedFirst runs before
	ReplicatedStorage.Shared replicates, so it cannot require Shared/Config/BrandAssets).
	image "" = not uploaded: the loading screen draws its text fallback instead.
]]

export type BrandImage = {{ read image: string, read size: Vector2 }}

local BrandImages = {{}}

BrandImages.Images = table.freeze({{
{body}
}}) :: {{ [string]: BrandImage }}

-- Stud panel texture (Shared/Config/PanelTextureAssets.AssetId), tiled as the backdrop.
BrandImages.StudTexture = {stud_image}

return table.freeze(BrandImages)
'''
    stylua = Path.home() / ".aftman/bin/stylua"
    for path, text in ((BRAND_LUAU, shared), (FIRST_LUAU, first)):
        path.parent.mkdir(parents=True, exist_ok=True)
        icons().atomic_write(path, text.encode())
        if stylua.is_file():
            subprocess.run([str(stylua), str(path)], check=True)
        print(f"Wrote {path.relative_to(ROOT)} ({sum(1 for v in ids.values() if v)}/{len(ids)} images mapped)")
    return 0


def command_open(_args=None) -> int:
    """Opens the brand deliverables in Preview for the owner (R12)."""
    files = [BRAND / name for name in ("logo.png", "logo-text.png", "nukey-1024.png", "keyart-1024.png")]
    subprocess.run(["/usr/bin/open", *[str(f) for f in files if f.is_file()]], check=False)
    return 0


def command_status(_args=None) -> int:
    """Files + uploaded ids."""
    ids = asset_ids()
    for name, (file, _) in UPLOADS.items():
        receipt = read_json(RECEIPTS / f"{name}.json", {})
        print(f"  {name:7} {file:16} id={ids[name]:<16} moderation={receipt.get('moderation', '-')}")
    for name in ("logo.png", "logo-text.png", "nukey-1024.png", "keyart-1024.png"):
        print(f"  {name:22} {'ok' if (BRAND / name).is_file() else 'missing'}")
    return 0


def main() -> int:
    """CLI entry (see module docstring)."""
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    render = commands.add_parser("render")
    render.add_argument("--only")
    render.set_defaults(handler=command_render)
    commands.add_parser("compose").set_defaults(handler=command_compose)
    commands.add_parser("title").set_defaults(handler=command_title)
    upload = commands.add_parser("upload")
    upload.add_argument("--user-id", required=True, type=int)
    upload.add_argument("--replace")
    upload.set_defaults(handler=command_upload)
    commands.add_parser("moderation").set_defaults(handler=command_moderation)
    commands.add_parser("sync").set_defaults(handler=command_sync)
    commands.add_parser("open").set_defaults(handler=command_open)
    commands.add_parser("status").set_defaults(handler=command_status)
    every = commands.add_parser("all")
    every.set_defaults(handler=lambda a: command_render(argparse.Namespace(only=None)) or command_compose() or command_open())
    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrandError as error:
        sys.exit(f"brand: {error}")
    except subprocess.CalledProcessError:
        sys.exit("brand: Blender render failed (rerun the Blender command by hand to see its log)")
