#!/usr/bin/env python3
"""Source, render, outline, review, upload and map every SellNukes 3D UI icon.

Owner R9 (2026-10-30): "make sure we do like the 3D icons ... rendered instead of like flat ...
they look 3D". Every UI icon (HUD buttons, currencies, offers, rewards, game objects, area icons)
is a chunky, glossy, shaded picture with a thick dark outline on a transparent 512 x 512 canvas —
the look of docs/reference/ui-style/*.png. Template: RoBeasts tools/ui/hud_icons.py.

Three source kinds (assets/icons/sources.json is the catalog + pins):
    pack       Microsoft Fluent Emoji 3D PNG (MIT, github.com/microsoft/fluentui-emoji), pinned by
               full commit + sha256. Trimmed to its alpha, colour-lifted (saturation / contrast,
               optional hue rotation for a palette match, e.g. the purple Gems), fitted to the box.
    blender    Original render from tools/blender/ui_icons/render_icons.py (shared soft-toon style)
               where no emoji fits (the cartoon nuke, the "31" calendar, the colour wheel, ...).
    composite  Several pack / Blender pictures layered (e.g. three eggs = TripleHatch, a dog + a
               green plus = PetSlots). Each layer gets a thin inner line so stacked items separate.
"parts" are pack / Blender pictures used only inside composites (never uploaded alone).

Pipeline (deterministic, no randomness):
    fetch       Downloads each pinned pack PNG (one fixed host, no redirects, size-capped) into
                assets/icons/sources/; refuses any whose sha256 differs. Sources are committed.
    render      Raw 2048 px pass per icon (pack / Blender / composite), then the thick OUTER outline
                (exact disc dilation of the alpha silhouette) and a 4:1 premultiplied downsample to
                assets/icons/<Key>.png; manifest.json records sha256 + alpha bounds; then `sheet`.
    sheet       assets/icons/contact-sheet.png (every icon on HUD-style tiles + a 44 px preview) and
                contact-sheet-small.png (40 / 56 / 96 px: phone HUD and TV legibility, owner R11).
    license     assets/icons/LICENSE.md from the catalog (per-icon sources + the MIT notice).
    upload      One Open Cloud Image asset per changed icon (journal written BEFORE each POST, an
                ambiguous POST is never retried, polled to a receipt with the sha256). Unchanged
                icons are skipped; an icon whose exact bytes another icon already uploaded reuses
                that asset (no duplicate assets). Then `sync`.
    moderation  Refreshes every receipt's moderation state (read-only GET), then `sync`.
    sync        Writes src/shared/Config/IconAssets.luau (GENERATED). An icon maps to "" when its
                receipt is missing, stale (sha256 differs from the manifest), malformed or Rejected.
    status      One line per icon.

Usage:
    python3 tools/ui/icons/icons.py fetch
    python3 tools/ui/icons/icons.py render [--only Shop,Cash]
    python3 tools/ui/icons/icons.py sheet
    python3 tools/ui/icons/icons.py upload --user-id 1586034782 [--only K] [--replace K|all] [--dry-run]
    python3 tools/ui/icons/icons.py moderation | sync | status
    python3 -m unittest discover -s tools/ui/icons -p 'test_*.py'
Requires numpy + Pillow (tools/ui/icons/requirements.txt; system python3 has both) and Blender
4.2+ (PATH or $BLENDER) for Blender-sourced icons. The API key is never printed (opencloud.py).
"""
from __future__ import annotations

import argparse
import hashlib
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
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT / "assets/icons"
RAW = DIRECTORY / "raw"
SOURCE_DIR = DIRECTORY / "sources"
JOURNALS = DIRECTORY / "journal"
RECEIPTS = DIRECTORY / "receipts"
HISTORY = DIRECTORY / "history"
MANIFEST = DIRECTORY / "manifest.json"
SOURCES = DIRECTORY / "sources.json"
SHEET = DIRECTORY / "contact-sheet.png"
CONFIG = ROOT / "src/shared/Config/IconAssets.luau"
BLENDER_SCRIPT = ROOT / "tools/blender/ui_icons/render_icons.py"

# ---------------------------------------------------------------------------------------------
# The contract with the UI kit (B2): every one of these keys exists in IconAssets, by category.
# ---------------------------------------------------------------------------------------------
CATEGORIES: dict[str, tuple[str, ...]] = {
    "hud": (
        "Shop", "Rewards", "Daily", "Codes", "LuckyWheel", "Time", "Pets", "Rebirth", "Teleport",
        "Attack", "Event", "Settings", "Admin",
        # R78 Friends (R-social): the Rewards hub tile, the Friends window and the Friend Boost chip.
        "Friends",
    ),
    # Bones / Amber = Dino Valley's currency + rebirth token (World 2, owner R57; WorldsConfig).
    # MoonRocks / StarShards = Moon Base's currency + rebirth token (World 3, owner R70).
    "currency": ("Cash", "Gems", "Acorn", "RebirthToken", "Bones", "Amber", "MoonRocks", "StarShards"),
    "offer": (
        "x2Cash", "StarterPack", "SecretPack", "VIP", "Spins", "Teleporter", "FastWalk", "AutoClicker",
        "OfflineMax", "LuckyEggs", "PetSlots", "TripleHatch", "AutoHatch", "MegaLauncher", "ServerBoost",
        "Barrage", "Shield", "SkipPad", "DoubleOffline", "GemPack", "CashPack", "TurkeyLure",
        # Dino Valley products (MonetizationConfig BonesSmall / BonesMedium / BonesLarge, TimeTravelerPack).
        "BonesPackSmall", "BonesPack", "BonesPackLarge", "TimeTravelerPack",
        # Moon Base products (MoonRocksSmall / MoonRocksMedium / MoonRocksLarge, AstronautPack; R70).
        "MoonRocksPackSmall", "MoonRocksPack", "MoonRocksPackLarge", "AstronautPack",
        # R78 Nuke Pass (P-pass): HUD Pass offer, NukePass window header, Quests banner, the product.
        "NukePass",
        # R89 Pocket Rocket (G-gifts): the HUD daily impulse offer + the PocketRocket product.
        "PocketRocket",
    ),
    "reward": ("GiftBox", "Chest", "Potion", "Key", "Torch", "Lock", "Check", "Star", "Trophy", "Clock"),
    "game": (
        "Nuke", "Reactor", "Manager", "Upgrade", "Egg", "Crate", "AATower", "Turkey", "Sticker", "Pie",
        "Notification",
        # Lucky Buttons (owner R69): the glowing arcade button (toasts, admin, the HUD arrow).
        "LuckyButton",
    ),
    "area": tuple(f"Area{index:02d}" for index in range(1, 11)),
    # Kit chrome used by UI/Kit/StudUI: the window close X, the tutorial arrow, the price-tag coin.
    "ui": ("Close", "Arrow", "Robux"),
    # Harvest Feast (B11): event pets / eggs, the 20 Feast Stickers (white die-cut sticker look),
    # the sticker sheet and the event decorations. Acorn / Trophy are reused from above.
    "event": (
        "GoldenTurkey", "GobbleBomb", "HarvestEgg", "StickerSheet",
        *(f"Sticker{index:02d}" for index in range(1, 21)),
        "DecorHayBales", "DecorPumpkinPile", "DecorScarecrow", "DecorCornucopia", "DecorGarland",
        "DecorTurkeyStatue",
    ),
    # Worlds (owner R57): the world-select tabs (one per world, in WorldsConfig order) and the
    # Time Machine portal (WORLD UNLOCKED popup, portal prompts). World 3 (Moon Base, R70) adds its
    # tab key WorldMoon and its lobby rocket portal MoonRocket.
    "world": ("WorldNukeTown", "WorldDino", "TimeMachine", "WorldMoon", "MoonRocket"),
}
ICONS: tuple[str, ...] = tuple(key for keys in CATEGORIES.values() for key in keys)
CATEGORY_OF = {key: category for category, keys in CATEGORIES.items() for key in keys}

# Extra names that resolve to an icon at runtime (IconAssets.get / image), so callers never need
# their own mapping tables:
#   * legacy keys of the pre-pipeline IconAssets stub (UI/Kit/Glyphs still knows them);
#   * MonetizationConfig product keys (DoubleCash, CashSmall, ...);
#   * MonetizationConfig's lowercase `icon` names ("crown", "cursor", ...).
# Anything else resolves case-insensitively through the generated `Lower` table (see lower_map).
ALIASES: dict[str, str] = {
    "Gem": "Gems",
    "X2Cash": "x2Cash",
    "Gift": "GiftBox",
    "DoubleCash": "x2Cash",
    "Cash2x30": "x2Cash",
    "CashSmall": "CashPack",
    "CashMedium": "CashPack",
    "CashLarge": "CashPack",
    "CashHuge": "CashPack",
    "GemsSmall": "GemPack",
    "GemsMedium": "GemPack",
    "GemsLarge": "GemPack",
    "Spins2": "Spins",
    "Spins5": "Spins",
    "Spins10": "Spins",
    "ServerCash2x": "ServerBoost",
    "Shield1h": "Shield",
    "AcornsSmall": "Acorn",
    "AcornsLarge": "Acorn",
    "BonesSmall": "BonesPackSmall",
    "BonesMedium": "BonesPack",
    "BonesLarge": "BonesPackLarge",
    "MoonRocksSmall": "MoonRocksPackSmall",
    "MoonRocksMedium": "MoonRocksPack",
    "MoonRocksLarge": "MoonRocksPackLarge",
    "NukePassPremium": "NukePass",
    "crown": "VIP",
    "cash": "Cash",
    "cursor": "AutoClicker",
    "boot": "FastWalk",
    "teleport": "Teleporter",
    "egg": "Egg",
    "pet": "Pets",
    "moon": "OfflineMax",
    "rocket": "MegaLauncher",
    "gem": "Gems",
    "spin": "Spins",
    "gift": "GiftBox",
    "star": "Star",
    "lightning": "ServerBoost",
    "clock": "Clock",
    "skip": "SkipPad",
    "shield": "Shield",
    "acorn": "Acorn",
    "turkey": "Turkey",
    "bones": "Bones",
    "amber": "Amber",
    "moonrocks": "MoonRocks",
    "starshards": "StarShards",
}

RAW_SIZE, FINAL_SIZE = 2048, 512
SUPERSAMPLE = RAW_SIZE // FINAL_SIZE
# Thick outer outline: 18 px of the final 512 image (~2 px on a 60 px HUD tile, the weight of the
# reference icons' strokes). Must match OUTLINE_PX in render_icons.py (its framing leaves room).
OUTLINE_PX = 18
# Outline colour = UIStyleConfig.TextStroke (20, 20, 28): icons and HUD text share one stroke.
OUTLINE_RGB = (20, 20, 28)
# Breathing room (final px) between the outline and the image edge.
PAD_PX = 6
# Inner line (final px) drawn around each composite layer so stacked items read separately.
INNER_PX = 8
# White die-cut border (final px) of "sticker" icons (the Feast Stickers), inside the dark outline.
STICKER_PX = 14
STICKER_RGB = (255, 255, 255)
# The colour lift that makes the pack's soft emoji colours read like the saturated simulator HUD.
PACK_SATURATION = 1.15
PACK_CONTRAST = 1.06
MAX_BYTES = 1_048_576
MAX_SOURCE_BYTES = 4_194_304
HASH = re.compile(r"[0-9a-f]{64}\Z")
ASSET_ID = re.compile(r"[1-9][0-9]{0,18}\Z")
KEY = re.compile(r"_?[A-Za-z][A-Za-z0-9]{0,40}\Z")
# Pack sources may only come from this repository, pinned to a full 40-hex commit.
SOURCE_URL = re.compile(
    r"https://raw\.githubusercontent\.com/microsoft/fluentui-emoji/[0-9a-f]{40}/assets/[A-Za-z0-9%_./-]{1,200}\.png\Z"
)
SOURCE_FILE = re.compile(r"[a-z0-9_-]{1,80}\.png\Z")


class ToolError(Exception):
    """A user-facing failure (printed without request bodies or credentials)."""


# =============================================================================================
# Small file helpers
# =============================================================================================


def read_json(path: Path, missing=None):
    """A JSON object from a regular file, or `missing` when absent. Rejects symlinks / non-objects."""
    if not path.exists():
        return missing
    if path.is_symlink() or not path.is_file():
        raise ToolError(f"{path.name} must be a regular file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        raise ToolError(f"{path.name} is not valid JSON") from None
    if not isinstance(value, dict):
        raise ToolError(f"{path.name} must hold a JSON object")
    return value


def atomic_write(path: Path, data: bytes) -> None:
    """Write via an fsynced temp file + rename so a crash never leaves a half-written file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".icons-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path: Path, value) -> None:
    """Deterministic pretty JSON, written atomically (journals, receipts, manifest)."""
    atomic_write(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def selected(only: str | None, universe=ICONS) -> list[str]:
    """The icon keys named by a comma list (validated against `universe`), or all of them."""
    if not only:
        return list(universe)
    names = [name.strip() for name in only.split(",") if name.strip()]
    for name in names:
        if name not in universe:
            raise ToolError(f"Unknown icon {name!r}")
    return names


# =============================================================================================
# Catalog (sources.json) validation
# =============================================================================================


def _check_pack(name: str, entry: dict) -> None:
    """A pack entry: pinned URL on the allowed repository, plain file name, sha256, emoji label."""
    if not isinstance(entry.get("url"), str) or not SOURCE_URL.fullmatch(entry["url"]):
        raise ToolError(f"{name}: source URL must be a pinned fluentui-emoji raw URL")
    if not isinstance(entry.get("file"), str) or not SOURCE_FILE.fullmatch(entry["file"]):
        raise ToolError(f"{name}: source file must be a plain lowercase .png name")
    if not urllib.parse.unquote(entry["url"]).endswith("/" + entry["file"]):
        raise ToolError(f"{name}: source file name must match its URL")
    if not isinstance(entry.get("sha256"), str) or not HASH.fullmatch(entry["sha256"]):
        raise ToolError(f"{name}: source sha256 must be pinned")
    if not isinstance(entry.get("emoji"), str) or not entry["emoji"]:
        raise ToolError(f"{name}: pack entries name their emoji")


def _check_number(name: str, entry: dict, field: str, low: float, high: float) -> None:
    """Optional numeric field within [low, high]."""
    if field in entry:
        value = entry[field]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not low <= value <= high:
            raise ToolError(f"{name}: {field} must be a number in [{low}, {high}]")


def catalog() -> dict:
    """
    sources.json, validated: {"icons": {...}, "parts": {...}}. Every ICONS key has exactly one
    entry; parts start with "_"; composite layers reference non-composite icons / parts only.
    Rejects anything unexpected rather than trusting it (the file decides network fetches).
    """
    sources = read_json(SOURCES)
    if sources is None:
        raise ToolError("assets/icons/sources.json is missing")
    icons, parts = sources.get("icons"), sources.get("parts", {})
    if not isinstance(icons, dict) or not isinstance(parts, dict):
        raise ToolError("sources.json needs 'icons' and 'parts' objects")
    if set(icons) != set(ICONS):
        missing, extra = sorted(set(ICONS) - set(icons)), sorted(set(icons) - set(ICONS))
        raise ToolError(f"sources.json icons mismatch: missing {missing}, unexpected {extra}")
    for name, entry in parts.items():
        if not KEY.fullmatch(name) or not name.startswith("_"):
            raise ToolError(f"part {name!r}: part names start with '_'")
        if not isinstance(entry, dict) or entry.get("kind") not in ("pack", "blender"):
            raise ToolError(f"{name}: parts are pack or blender")
    every = {**icons, **parts}
    for name, entry in every.items():
        if not isinstance(entry, dict) or entry.get("kind") not in ("pack", "blender", "composite"):
            raise ToolError(f"{name}: needs kind pack, blender or composite")
        _check_number(name, entry, "hue", -180, 180)
        _check_number(name, entry, "saturation", 0.5, 2.0)
        _check_number(name, entry, "tilt", -30, 30)
        stops = entry.get("colorize")
        if stops is not None and not (
            isinstance(stops, list)
            and len(stops) == 3
            and all(
                isinstance(stop, list) and len(stop) == 3 and all(type(c) is int and 0 <= c <= 255 for c in stop)
                for stop in stops
            )
        ):
            raise ToolError(f"{name}: colorize must be three [r, g, b] stops (0..255)")
        if "sticker" in entry and (not isinstance(entry["sticker"], bool) or name.startswith("_")):
            raise ToolError(f"{name}: sticker must be true / false (icons only)")
        if entry["kind"] == "pack":
            _check_pack(name, entry)
        elif entry["kind"] == "composite":
            layers = entry.get("layers")
            if not isinstance(layers, list) or not 1 <= len(layers) <= 6:
                raise ToolError(f"{name}: composites need 1..6 layers")
            for layer in layers:
                if not isinstance(layer, dict):
                    raise ToolError(f"{name}: invalid layer")
                ref = layer.get("ref")
                if ref not in every or every[ref].get("kind") == "composite":
                    raise ToolError(f"{name}: layer ref {ref!r} must be a pack / blender icon or part")
                _check_number(name, layer, "x", -1, 1)
                _check_number(name, layer, "y", -1, 1)
                _check_number(name, layer, "scale", 0.1, 1.5)
                _check_number(name, layer, "rotate", -180, 180)
                _check_number(name, layer, "hue", -180, 180)
    return every


def notice() -> str:
    """The pack licence notice carried by every uploaded asset that contains Fluent art."""
    return (
        "Microsoft Fluent Emoji 3D (github.com/microsoft/fluentui-emoji), MIT License, "
        "Copyright (c) Microsoft Corporation. Outline, colour lift and composites by SellNukes."
    )


def pack_files(entry: dict, every: dict) -> list[dict]:
    """The pack entries an icon depends on (itself, or its composite layers' pack refs)."""
    if entry["kind"] == "pack":
        return [entry]
    if entry["kind"] == "composite":
        return [every[layer["ref"]] for layer in entry["layers"] if every[layer["ref"]]["kind"] == "pack"]
    return []


# =============================================================================================
# fetch
# =============================================================================================


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect would leave the pinned URL: refuse it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401 - urllib API
        """Returning None makes urllib fail on any redirect."""
        return None


def command_fetch(_args=None) -> int:
    """Downloads missing pack sources from their pinned URLs; keeps only exact-hash matches."""
    every = catalog()
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    if Path("/etc/ssl/cert.pem").is_file():
        os.environ.setdefault("SSL_CERT_FILE", "/etc/ssl/cert.pem")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    seen: set[str] = set()
    for name, entry in sorted(every.items()):
        if entry["kind"] != "pack" or entry["file"] in seen:
            continue
        seen.add(entry["file"])
        path = SOURCE_DIR / entry["file"]
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]:
            continue
        try:
            with opener.open(urllib.request.Request(entry["url"], method="GET"), timeout=30) as response:
                data = response.read(MAX_SOURCE_BYTES + 1)
        except (OSError, urllib.error.URLError):
            raise ToolError(f"{name}: download failed") from None
        if len(data) > MAX_SOURCE_BYTES or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ToolError(f"{name}: downloaded bytes do not match the pinned sha256; nothing written")
        atomic_write(path, data)
        print(f"  {name}: fetched {entry['file']} ({len(data)} bytes)")
    print(f"Pack sources pinned: {len(seen)} files in {SOURCE_DIR.relative_to(ROOT)}")
    return 0


# =============================================================================================
# render: image helpers
# =============================================================================================


def dilate(mask, radius: int):
    """
    Exact disc dilation of a boolean mask (round-cornered outline). A disc is the union of
    horizontal runs: row offset dy has half-width floor(sqrt(r^2 - dy^2)); each run is a 1D box
    dilation done in O(n) with a row prefix sum, shifted by dy and OR-ed in. Equal widths are
    computed once. Cost: (2r + 1) shifted ORs instead of pi r^2 for a naive disc.
    Example: dilate(alpha > 0.5, 72) -> mask grown by 72 px in every direction.
    """
    import numpy as np

    height, width = mask.shape
    padded = np.zeros((height, width + 2 * radius + 1), dtype=np.int32)
    padded[:, radius + 1 : radius + 1 + width] = mask
    prefix = np.cumsum(padded, axis=1)
    columns = np.arange(width)
    runs: dict[int, object] = {}
    out = np.zeros_like(mask, dtype=bool)
    for dy in range(-radius, radius + 1):
        half = int(math.floor(math.sqrt(radius * radius - dy * dy)))
        row = runs.get(half)
        if row is None:
            row = (prefix[:, columns + half + radius + 1] - prefix[:, columns - half + radius]) > 0
            runs[half] = row
        if dy >= 0:
            out[dy:] |= row[: height - dy]
        else:
            out[: height + dy] |= row[-dy:]
    return out


def colorize(image, stops):
    """
    Remaps an RGBA image's luminance onto a dark -> mid -> light gradient (alpha untouched):
    keeps all the 3D shading but turns any colour into e.g. true gold (a dark brown turkey can't
    become gold by hue rotation alone). Luminance is auto-stretched so the full ramp is used.
    Example: colorize(img, [[150, 90, 20], [255, 190, 40], [255, 246, 176]])
    """
    from PIL import Image, ImageOps

    if not stops:
        return image
    alpha = image.getchannel("A")
    grey = ImageOps.autocontrast(image.convert("L"), cutoff=1)
    rgb = ImageOps.colorize(grey, black=tuple(stops[0]), mid=tuple(stops[1]), white=tuple(stops[2]))
    return Image.merge("RGBA", (*rgb.convert("RGB").split(), alpha))


def hue_rotate(image, degrees: float):
    """Rotates the hue of an RGBA image by `degrees` (alpha untouched). 0 returns the input."""
    from PIL import Image

    if not degrees:
        return image
    alpha = image.getchannel("A")
    h, s, v = image.convert("RGB").convert("HSV").split()
    shift = int(round(degrees / 360 * 256)) % 256
    h = h.point(lambda value: (value + shift) % 256)
    rgb = Image.merge("HSV", (h, s, v)).convert("RGB")
    return Image.merge("RGBA", (*rgb.split(), alpha))


def over(dst, src):
    """Premultiplied 'src over dst' for float RGBA arrays (straight alpha in, straight out)."""
    import numpy as np

    sa, da = src[..., 3:4], dst[..., 3:4]
    out_a = sa + da * (1 - sa)
    rgb = src[..., :3] * sa + dst[..., :3] * da * (1 - sa)
    rgb = np.where(out_a > 0, rgb / np.maximum(out_a, 1e-9), 0)
    return np.concatenate([rgb, out_a], axis=-1)


def with_outline(layer, radius: int):
    """`layer` (float RGBA) composited over a flat OUTLINE_RGB disc dilation of its silhouette."""
    import numpy as np

    line = np.zeros_like(layer)
    line[..., :3] = np.array(OUTLINE_RGB, dtype=np.float64) / 255.0
    line[..., 3] = dilate(layer[..., 3] > 0.5, radius)
    return over(line, layer)


def box_px() -> int:
    """Raw px of the shared art box: the art's longer side fills this (outline + pad outside)."""
    return (FINAL_SIZE - 2 * (OUTLINE_PX + PAD_PX)) * SUPERSAMPLE


def trimmed(image):
    """An RGBA image cropped to its alpha bounds (raises on fully transparent input)."""
    bounds = image.getchannel("A").getbbox()
    if bounds is None:
        raise ToolError("image is fully transparent")
    return image.crop(bounds)


def pack_source(name: str, entry: dict) -> bytes:
    """The pinned source PNG of a pack entry (regular file in sources/, hash-checked)."""
    path = SOURCE_DIR / entry["file"]
    if path.is_symlink() or not path.is_file() or path.resolve().parent != SOURCE_DIR.resolve():
        raise ToolError(f"{name}: source must be a regular file in sources/; run fetch")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != entry["sha256"] or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ToolError(f"{name}: source PNG does not match its pinned sha256")
    return data


def prepared(name: str, every: dict):
    """
    The trimmed RGBA art of a pack / Blender icon or part at its native resolution:
    pack = pinned PNG, colour lift (+ optional hue rotation); blender = raw render.
    """
    from PIL import Image, ImageEnhance

    entry = every[name]
    if entry["kind"] == "pack":
        Image.MAX_IMAGE_PIXELS = 4096 * 4096
        with Image.open(io.BytesIO(pack_source(name, entry))) as opened:
            if max(opened.size) > 4096:
                raise ToolError(f"{name}: source is larger than 4096 px")
            source = trimmed(opened.convert("RGBA"))
        alpha = source.getchannel("A")
        color = ImageEnhance.Color(source.convert("RGB")).enhance(entry.get("saturation", PACK_SATURATION))
        color = ImageEnhance.Contrast(color).enhance(PACK_CONTRAST)
        lifted = Image.merge("RGBA", (*color.split(), alpha))
        return hue_rotate(colorize(lifted, entry.get("colorize")), entry.get("hue", 0))
    path = RAW / f"{name}.png"
    Image.MAX_IMAGE_PIXELS = RAW_SIZE * RAW_SIZE
    with Image.open(path) as opened:
        return hue_rotate(trimmed(opened.convert("RGBA")), entry.get("hue", 0))


def fitted(art):
    """`art` scaled (Lanczos) so its longer side fills the shared box, centred on a raw canvas."""
    from PIL import Image

    box = box_px()
    scale = box / max(art.size)
    size = (max(1, round(art.width * scale)), max(1, round(art.height * scale)))
    art = art.resize(size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (RAW_SIZE, RAW_SIZE), (0, 0, 0, 0))
    canvas.alpha_composite(art, ((RAW_SIZE - size[0]) // 2, (RAW_SIZE - size[1]) // 2))
    return canvas


def composite_raw(name: str, entry: dict, every: dict):
    """
    A composite's raw pass. Layer placement is in box units: `scale` 1 = the layer's longer side
    fills the box; (x, y) = offset of its centre from the box centre (y up); `rotate` degrees CCW.
    Two passes: lay out at unit fit, measure the union (incl. inner lines), then re-lay at the fit
    factor that makes the union fill the box exactly, so composites frame like every other icon.
    Each layer is drawn over a thin INNER_PX outline of itself (back-to-front order).
    """
    import numpy as np
    from PIL import Image

    box = box_px()
    inner = INNER_PX * SUPERSAMPLE
    arts = []
    for layer in entry["layers"]:
        art = prepared(layer["ref"], every)
        if layer.get("hue"):
            art = hue_rotate(art, layer["hue"])
        arts.append(art)

    def placed(fit: float):
        """[(image, (left, top))] of every layer at fit factor `fit` around a (0, 0) origin."""
        result = []
        for layer, art in zip(entry["layers"], arts):
            longer = layer.get("scale", 1.0) * box * fit
            scale = longer / max(art.size)
            size = (max(1, round(art.width * scale)), max(1, round(art.height * scale)))
            image = art.resize(size, Image.Resampling.LANCZOS)
            if layer.get("rotate"):
                image = image.rotate(layer["rotate"], resample=Image.Resampling.BICUBIC, expand=True)
            cx = layer.get("x", 0.0) * box * fit
            cy = -layer.get("y", 0.0) * box * fit
            result.append((image, (cx - image.width / 2, cy - image.height / 2)))
        return result

    def union(items):
        """Alpha-bounds union (x0, y0, x1, y1) of placed layers."""
        x0 = y0 = math.inf
        x1 = y1 = -math.inf
        for image, (left, top) in items:
            bounds = image.getchannel("A").getbbox()
            if bounds is None:
                continue
            x0, y0 = min(x0, left + bounds[0]), min(y0, top + bounds[1])
            x1, y1 = max(x1, left + bounds[2]), max(y1, top + bounds[3])
        return x0, y0, x1, y1

    x0, y0, x1, y1 = union(placed(1.0))
    fit = (box - 2 * inner) / max(x1 - x0, y1 - y0)
    items = placed(fit)
    x0, y0, x1, y1 = union(items)
    dx, dy = RAW_SIZE / 2 - (x0 + x1) / 2, RAW_SIZE / 2 - (y0 + y1) / 2
    canvas = np.zeros((RAW_SIZE, RAW_SIZE, 4), dtype=np.float64)
    for image, (left, top) in items:
        layer = Image.new("RGBA", (RAW_SIZE, RAW_SIZE), (0, 0, 0, 0))
        layer.alpha_composite(image, (round(left + dx), round(top + dy)))
        pixels = np.asarray(layer, dtype=np.float64) / 255.0
        canvas = over(canvas, with_outline(pixels, inner))
    return Image.fromarray(np.clip(np.round(canvas * 255), 0, 255).astype(np.uint8), "RGBA")


def stickered(raw, tilt: float):
    """
    The die-cut sticker look: the art (optionally tilted `tilt` degrees CCW for a hand-stuck feel)
    re-fitted STICKER_PX smaller per side, then a flat white disc dilation of its silhouette under
    it. The dark outer outline is added afterwards as for every icon, so stickers read as
    white-bordered stickers on any background while keeping the shared framing.
    """
    import numpy as np
    from PIL import Image

    border = STICKER_PX * SUPERSAMPLE
    art = trimmed(raw)
    if tilt:
        art = trimmed(art.rotate(tilt, resample=Image.Resampling.BICUBIC, expand=True))
    box = box_px() - 2 * border
    scale = box / max(art.size)
    size = (max(1, round(art.width * scale)), max(1, round(art.height * scale)))
    canvas = Image.new("RGBA", (RAW_SIZE, RAW_SIZE), (0, 0, 0, 0))
    canvas.alpha_composite(art.resize(size, Image.Resampling.LANCZOS), ((RAW_SIZE - size[0]) // 2, (RAW_SIZE - size[1]) // 2))
    pixels = np.asarray(canvas, dtype=np.float64) / 255.0
    white = np.zeros_like(pixels)
    white[..., :3] = np.array(STICKER_RGB, dtype=np.float64) / 255.0
    white[..., 3] = dilate(pixels[..., 3] > 0.5, border)
    merged = over(white, pixels)
    return Image.fromarray(np.clip(np.round(merged * 255), 0, 255).astype(np.uint8), "RGBA")


def outline_and_downsample(raw):
    """
    The final 512 px RGBA icon of one raw 2048 px pass: the art OVER a flat outline layer (exact
    disc dilation of the silhouette, OUTLINE_PX final px), then a 4:1 box downsample in
    premultiplied space (no dark fringes on anti-aliased edges). Returns (image, alpha bounds).
    """
    import numpy as np
    from PIL import Image

    if raw.size != (RAW_SIZE, RAW_SIZE):
        raise ToolError(f"expected a {RAW_SIZE} px raw pass, got {raw.size}")
    source = np.asarray(raw.convert("RGBA"), dtype=np.float64) / 255.0
    merged = with_outline(source, OUTLINE_PX * SUPERSAMPLE)
    alpha = merged[..., 3]
    premultiplied = merged[..., :3] * alpha[..., None]
    shape = (FINAL_SIZE, SUPERSAMPLE, FINAL_SIZE, SUPERSAMPLE)
    color = premultiplied.reshape(shape + (3,)).mean(axis=(1, 3))
    cover = alpha.reshape(shape).mean(axis=(1, 3))
    rgb = np.where(cover[..., None] > 0, color / np.maximum(cover[..., None], 1e-9), 0)
    image = Image.fromarray(np.clip(np.round(np.dstack([rgb, cover]) * 255), 0, 255).astype(np.uint8), "RGBA")
    bounds = image.getchannel("A").getbbox()
    if bounds is None or min(bounds[2] - bounds[0], bounds[3] - bounds[1]) < FINAL_SIZE // 5:
        raise ToolError("empty or unexpectedly small icon")
    if bounds[0] == 0 or bounds[1] == 0 or bounds[2] == FINAL_SIZE or bounds[3] == FINAL_SIZE:
        raise ToolError("the outline touches the image edge (framing too tight)")
    return image, bounds


# =============================================================================================
# render: command
# =============================================================================================


def run_blender(names: list[str]) -> None:
    """Renders the named Blender icons / parts (raw 2048 px passes) in ONE Blender process."""
    if not names:
        return
    blender = os.environ.get("BLENDER") or shutil.which("blender")
    if not blender:
        raise ToolError("Blender not found: put it on PATH or set $BLENDER")
    # Fixed argument vector (no shell): Blender's own flags, then ours after "--".
    subprocess.run(
        [
            blender,
            "--background",
            "--factory-startup",
            "--python-exit-code",
            "1",
            "--python",
            str(BLENDER_SCRIPT),
            "--",
            str(RAW),
            *names,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def command_render(args: argparse.Namespace) -> int:
    """Raw pass of each selected icon (+ the parts its composite needs), outline, manifest, sheet."""
    names = selected(args.only)
    every = catalog()
    RAW.mkdir(parents=True, exist_ok=True)
    needed: list[str] = []
    for name in names:
        refs = [layer["ref"] for layer in every[name]["layers"]] if every[name]["kind"] == "composite" else [name]
        for ref in refs:
            if ref not in needed:
                needed.append(ref)
    run_blender([name for name in needed if every[name]["kind"] == "blender"])
    manifest = read_json(MANIFEST, {"icons": {}})
    for name in names:
        entry = every[name]
        # Pack and Blender art are both trimmed and re-fitted to the shared box, so every source
        # kind frames identically (Blender's own framing only has to be close).
        raw = composite_raw(name, entry, every) if entry["kind"] == "composite" else fitted(prepared(name, every))
        if entry.get("sticker"):
            raw = stickered(raw, entry.get("tilt", 0))
        try:
            image, bounds = outline_and_downsample(raw)
        except ToolError as error:
            raise ToolError(f"{name}: {error}") from None
        buffer = io.BytesIO()
        image.save(buffer, format="PNG", optimize=True)
        data = buffer.getvalue()
        if len(data) > MAX_BYTES:
            raise ToolError(f"{name}: {len(data)} bytes exceeds the {MAX_BYTES} byte upload budget")
        atomic_write(DIRECTORY / f"{name}.png", data)
        manifest["icons"][name] = {
            "file": f"{name}.png",
            "size": [FINAL_SIZE, FINAL_SIZE],
            "category": CATEGORY_OF[name],
            "source": entry["kind"],
            "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data),
            "alphaBounds": list(bounds),
        }
        print(f"  {name:13} {entry['kind']:9} {len(data):7} bytes  alpha {bounds}")
    manifest["icons"] = {key: manifest["icons"][key] for key in ICONS if key in manifest["icons"]}
    atomic_json(MANIFEST, manifest)
    command_license()
    return command_sheet()


# =============================================================================================
# license: assets/icons/LICENSE.md generated from the catalog (never drifts from sources.json)
# =============================================================================================

MIT_TEXT = """MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""


def describe(name: str, every: dict) -> tuple[str, str]:
    """(source description, licence) of one icon / part for the LICENSE.md table."""
    entry = every[name]
    if entry["kind"] == "pack":
        return f'Fluent Emoji 3D: {entry["emoji"]}', "MIT"
    if entry["kind"] == "blender":
        return "Original SellNukes Blender render", "SellNukes"
    layers = ", ".join(dict.fromkeys(layer["ref"] for layer in entry["layers"]))
    has_pack = any(every[layer["ref"]]["kind"] == "pack" for layer in entry["layers"])
    return f"Composite of {layers}", "MIT + SellNukes" if has_pack else "SellNukes"


def command_license(_args=None) -> int:
    """Writes assets/icons/LICENSE.md: per-icon sources + the full Fluent Emoji MIT notice."""
    every = catalog()
    commit = next(entry["url"].split("/")[5] for entry in every.values() if entry["kind"] == "pack")
    lines = [
        "# SellNukes UI icon sources and licences",
        "",
        "GENERATED by `tools/ui/icons/icons.py license` from `sources.json` (runbook: `docs/icons.md`).",
        "Shipped as Roblox Image assets; pinned URLs + sha256: `sources.json`; pinned PNGs: `sources/`.",
        "",
        f"Fluent Emoji source: https://github.com/microsoft/fluentui-emoji at commit `{commit}`",
        "(`assets/<Name>/3D/*.png`). MIT permits commercial use, modification and redistribution and",
        "requires only that the notice below travels with copies: it is kept here, in the generated",
        "`src/shared/Config/IconAssets.luau` header and in every uploaded asset's description.",
        "SellNukes modifications: trimmed, saturation / contrast lift, optional hue rotation, layered",
        "composites, scaled to 512 x 512 and given a thick dark outline.",
        "",
        "| Key | Category | Source | Licence |",
        "|-----|----------|--------|---------|",
    ]
    for name in ICONS:
        source, licence = describe(name, every)
        lines.append(f"| {name} | {CATEGORY_OF[name]} | {source} | {licence} |")
    lines += ["", "Composite parts (never uploaded alone):", "", "| Part | Source | Licence |", "|------|--------|---------|"]
    for name in sorted(key for key in every if key.startswith("_")):
        source, licence = describe(name, every)
        lines.append(f"| {name} | {source} | {licence} |")
    lines += ["", "## Microsoft Fluent Emoji: MIT License", "", MIT_TEXT, ""]
    atomic_write(DIRECTORY / "LICENSE.md", "\n".join(lines).encode())
    print(f"Wrote {(DIRECTORY / 'LICENSE.md').relative_to(ROOT)}")
    return 0


# =============================================================================================
# sheet: contact sheet for visual review
# =============================================================================================

# Stud-button tile colours (UI kit families) cycled per category so icons are judged on the
# backgrounds they will actually sit on.
TILE_COLORS = {
    "hud": (255, 196, 40),
    "currency": (52, 64, 92),
    "offer": (230, 70, 80),
    "reward": (80, 200, 90),
    "game": (70, 140, 230),
    "area": (150, 96, 220),
    "ui": (230, 70, 80),
    "event": (236, 128, 40),
    "world": (60, 170, 150),
}


def _font(size: int):
    """A bold system font for labels when available (review sheet only), else Pillow's default."""
    from PIL import ImageFont

    for path in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/Library/Fonts/Arial Bold.ttf"):
        if Path(path).is_file():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def command_sheet(_args=None) -> int:
    """assets/icons/contact-sheet.png: one HUD-style tile per icon (150 px + a 44 px preview)."""
    from PIL import Image, ImageDraw

    columns, cell_w, cell_h, icon = 10, 196, 214, 150
    rows = math.ceil(len(ICONS) / columns)
    sheet = Image.new("RGB", (columns * cell_w, rows * cell_h), (34, 38, 52))
    draw = ImageDraw.Draw(sheet)
    font = _font(15)
    for index, name in enumerate(ICONS):
        x, y = (index % columns) * cell_w, (index // columns) * cell_h
        color = TILE_COLORS[CATEGORY_OF[name]]
        draw.rounded_rectangle((x + 6, y + 6, x + cell_w - 6, y + cell_h - 30), 18, fill=color, outline=(20, 20, 28), width=4)
        path = DIRECTORY / f"{name}.png"
        if path.is_file():
            with Image.open(path) as opened:
                art = opened.convert("RGBA")
            big = art.resize((icon, icon), Image.Resampling.LANCZOS)
            sheet.paste(big, (x + (cell_w - icon) // 2, y + 12), big)
            small = art.resize((44, 44), Image.Resampling.LANCZOS)
            sheet.paste(small, (x + cell_w - 54, y + cell_h - 78), small)
        else:
            draw.text((x + 20, y + 80), "not rendered", fill=(20, 20, 28), font=font)
        draw.text((x + 10, y + cell_h - 26), name, fill=(240, 240, 248), font=font)
    buffer = io.BytesIO()
    sheet.save(buffer, format="PNG", optimize=True)
    atomic_write(SHEET, buffer.getvalue())
    print(f"Wrote {SHEET.relative_to(ROOT)}")
    return small_sheet()


def small_sheet() -> int:
    """
    Owner R11 legibility check: assets/icons/contact-sheet-small.png shows every icon at phone HUD
    sizes (40 and 56 px) on its tile colour and at a TV-distance 96 px, side by side, so anything
    that turns to mush when small is caught before upload.
    """
    from PIL import Image, ImageDraw

    columns, cell_w, cell_h = 6, 300, 118
    rows = math.ceil(len(ICONS) / columns)
    sheet = Image.new("RGB", (columns * cell_w, rows * cell_h), (34, 38, 52))
    draw = ImageDraw.Draw(sheet)
    font = _font(13)
    for index, name in enumerate(ICONS):
        x, y = (index % columns) * cell_w, (index // columns) * cell_h
        color = TILE_COLORS[CATEGORY_OF[name]]
        path = DIRECTORY / f"{name}.png"
        if not path.is_file():
            continue
        with Image.open(path) as opened:
            art = opened.convert("RGBA")
        left = x + 6
        for size in (40, 56, 96):
            draw.rounded_rectangle((left - 3, y + 6, left + size + 3, y + 6 + size + 6), 8, fill=color, outline=(20, 20, 28), width=2)
            small = art.resize((size, size), Image.Resampling.LANCZOS)
            sheet.paste(small, (left, y + 9), small)
            left += size + 14
        draw.text((x + 8, y + cell_h - 16), name, fill=(240, 240, 248), font=font)
    path = DIRECTORY / "contact-sheet-small.png"
    buffer = io.BytesIO()
    sheet.save(buffer, format="PNG", optimize=True)
    atomic_write(path, buffer.getvalue())
    print(f"Wrote {path.relative_to(ROOT)}")
    return 0


# =============================================================================================
# upload (one Image asset per distinct picture) + moderation refresh
# =============================================================================================


def cloud():
    """The sibling opencloud module (loaded by path; stdlib only)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        import opencloud
    finally:
        sys.path.pop(0)
    return opencloud


def validated_icon(name: str, manifest: dict) -> tuple[bytes, str]:
    """The exact PNG bytes recorded in the manifest (format, size and hash checked)."""
    path = DIRECTORY / f"{name}.png"
    if path.is_symlink() or not path.is_file():
        raise ToolError(f"{name}: icon must be a regular file; run render first")
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    entry = manifest.get("icons", {}).get(name, {})
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) > MAX_BYTES or digest != entry.get("sha256"):
        raise ToolError(f"{name}: PNG format, size or manifest hash failed validation; rerun render")
    return data, digest


def retire(name: str) -> None:
    """Moves an icon's receipt + journal to history/<Key>/<sha12>/ before a new picture uploads."""
    receipt_path, journal_path = RECEIPTS / f"{name}.json", JOURNALS / f"{name}.json"
    old = read_json(receipt_path, {}) or read_json(journal_path, {})
    if not old:
        return
    if old.get("status") in ("submitting", "pending"):
        raise ToolError(f"{name}: an unfinished operation is journaled; rerun upload to resume it first")
    folder = HISTORY / name / str(old.get("sha256", "unknown"))[:12]
    folder.mkdir(parents=True, exist_ok=True)
    for path in (receipt_path, journal_path):
        if path.is_file():
            os.replace(path, folder / path.name)
    print(f"  {name}: retired the previous upload to {folder.relative_to(ROOT)}")


def upload_one(name: str, data: bytes, identity: dict, client, description: str) -> dict:
    """
    Creates (or resumes) one Image asset and returns its receipt. The journal is persisted BEFORE
    the POST ("submitting") and with the operation path BEFORE polling ("pending"); a crash during
    the POST leaves "submitting", which blocks an automatic duplicate create (reconcile by hand).
    """
    journal_path, receipt_path = JOURNALS / f"{name}.json", RECEIPTS / f"{name}.json"
    old = read_json(journal_path, {})
    if old and any(old.get(k) != v for k, v in identity.items()):
        raise ToolError(f"{name}: journaled upload identity differs; reconcile, then --replace {name}")
    entry = old or {**identity, "status": "submitting"}
    if old and entry.get("status") == "submitting":
        raise ToolError(f"{name}: prior POST outcome unknown; check Creator Dashboard, then remove journal/{name}.json")
    if not old:
        atomic_json(journal_path, entry)
        response = client.create_image(f"SellNukes icon {name}", description, data, f"icon-{name}.png", identity["creator"])
        operation = response.get("path")
        if not isinstance(operation, str) or not client_operation_ok(operation):
            raise ToolError(f"{name}: unknown POST outcome; reconcile before retrying")
        entry.update(status="pending", operation=operation)
        atomic_json(journal_path, entry)
    deadline = time.monotonic() + 180
    while entry.get("status") == "pending":
        response = client.poll(entry.get("operation"))
        if response.get("done") is True:
            asset = response.get("response", {})
            asset_id = asset.get("assetId") if isinstance(asset, dict) else None
            if response.get("error") or not ASSET_ID.fullmatch(str(asset_id)):
                entry["status"] = "failed"
                atomic_json(journal_path, entry)
                raise ToolError(f"{name}: asset operation failed; reconcile before creating another asset")
            moderation = asset.get("moderationResult", {})
            state = moderation.get("moderationState", "unknown") if isinstance(moderation, dict) else "unknown"
            entry.update(status="complete", assetId=int(asset_id), moderation=str(state)[:32])
            atomic_json(journal_path, entry)
        elif time.monotonic() >= deadline:
            raise ToolError(f"{name}: polling timed out; rerun upload to resume the operation")
        else:
            time.sleep(3)
    if entry.get("status") != "complete":
        raise ToolError(f"{name}: journal needs reconciliation ({entry.get('status')}); no POST retried")
    receipt = {**identity, "assetId": entry["assetId"], "moderation": entry.get("moderation", "unknown")}
    atomic_json(receipt_path, receipt)
    return receipt


def client_operation_ok(operation: str) -> bool:
    """True for a well-formed operation path (validated again inside opencloud.poll)."""
    return bool(re.fullmatch(r"operations/[A-Za-z0-9_-]{1,200}", operation))


class _Lock:
    """Process-exclusive lock on assets/icons so two uploaders never race one journal."""

    def __enter__(self):
        import fcntl

        DIRECTORY.mkdir(parents=True, exist_ok=True)
        self.handle = (DIRECTORY / ".upload.lock").open("a")
        try:
            fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.handle.close()
            raise ToolError("another icon uploader holds assets/icons/.upload.lock") from None
        return self

    def __exit__(self, *_):
        import fcntl

        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()


def command_upload(args: argparse.Namespace) -> int:
    """Uploads every icon whose exact bytes are not uploaded yet (dedupes identical pictures)."""
    if args.user_id <= 0:
        raise ToolError("User ID must be positive")
    manifest = read_json(MANIFEST, {"icons": {}})
    every = catalog()
    creator = {"userId": str(args.user_id)}
    replace = set(ICONS) if args.replace == "all" else set(selected(args.replace)) if args.replace else set()
    plan: list[tuple[str, bytes, dict]] = []
    for name in selected(args.only):
        data, digest = validated_icon(name, manifest)
        identity = {"icon": name, "sha256": digest, "creator": creator, "assetType": "Image"}
        receipt = read_json(RECEIPTS / f"{name}.json", {})
        if receipt and all(receipt.get(k) == v for k, v in identity.items()):
            continue  # this exact picture is already uploaded for this key
        if receipt and name not in replace:
            raise ToolError(f"{name}: a different picture is already uploaded; pass --replace {name} (or all)")
        plan.append((name, data, identity))
    if args.dry_run:
        summary = [{"icon": n, "bytes": len(d), "sha256": i["sha256"]} for n, d, i in plan]
        print(json.dumps({"creator": creator, "upload": summary, "dryRun": True}, indent=2))
        return 0
    if not plan:
        print("Nothing to upload (every icon's current picture already has a receipt).")
        return command_sync()
    JOURNALS.mkdir(parents=True, exist_ok=True)
    RECEIPTS.mkdir(parents=True, exist_ok=True)
    module = cloud()
    try:
        client = module.Client(module.read_key())
        with _Lock():
            for index, (name, data, identity) in enumerate(plan):
                if name in replace:
                    retire(name)
                # Same bytes already uploaded under another key (e.g. Rewards = GiftBox): reuse it.
                twin = next(
                    (
                        r
                        for r in (read_json(p, {}) for p in sorted(RECEIPTS.glob("*.json")))
                        if r.get("sha256") == identity["sha256"]
                        and r.get("creator") == creator
                        and str(r.get("moderation", "")).lower() != "rejected"
                        and ASSET_ID.fullmatch(str(r.get("assetId")))
                    ),
                    None,
                )
                if twin is not None:
                    receipt = {**identity, "assetId": twin["assetId"], "moderation": twin.get("moderation", "unknown"), "sharedWith": twin["icon"]}
                    atomic_json(RECEIPTS / f"{name}.json", receipt)
                    print(f"  {name}: reuses {twin['icon']}'s Image asset {twin['assetId']}")
                    continue
                kind = every[name]["kind"]
                description = f"SellNukes UI icon: {name} ({CATEGORY_OF[name]})."
                if pack_files(every[name], every):
                    description += " " + notice()
                elif kind == "blender":
                    description += " Original Blender render."
                receipt = upload_one(name, data, identity, client, description)
                print(f"  {name}: Image asset {receipt['assetId']} ({receipt['moderation']})")
                if index + 1 < len(plan):
                    time.sleep(1)  # stay well under the Open Cloud assets rate limit
    except module.CloudError as error:
        raise ToolError(str(error)) from None
    return command_sync()


def command_moderation(_args=None) -> int:
    """Refreshes every receipt's moderation state (read-only GET per distinct asset), then syncs."""
    module = cloud()
    try:
        client = module.Client(module.read_key())
        states: dict[int, str] = {}
        with _Lock():
            for name in ICONS:
                path = RECEIPTS / f"{name}.json"
                receipt = read_json(path, {})
                asset_id = receipt.get("assetId")
                if type(asset_id) is not int:
                    continue
                if asset_id not in states:
                    states[asset_id] = client.moderation(asset_id)
                if states[asset_id] != receipt.get("moderation"):
                    receipt["moderation"] = states[asset_id]
                    atomic_json(path, receipt)
    except module.CloudError as error:
        raise ToolError(str(error)) from None
    counts: dict[str, int] = {}
    for state in states.values():
        counts[state] = counts.get(state, 0) + 1
    print(f"Moderation of {len(states)} distinct assets: {counts}")
    return command_sync()


# =============================================================================================
# sync (generated Luau config) + status
# =============================================================================================


def receipt_asset(name: str, manifest: dict) -> int:
    """The uploaded asset id of an icon, or 0 (no / stale / invalid receipt, or Rejected)."""
    receipt = read_json(RECEIPTS / f"{name}.json", {})
    asset_id = receipt.get("assetId")
    if type(asset_id) is not int or not ASSET_ID.fullmatch(str(asset_id)):
        return 0
    if receipt.get("sha256") != manifest.get("icons", {}).get(name, {}).get("sha256"):
        return 0  # the PNG changed since this upload: never map a stale picture
    if str(receipt.get("moderation", "")).lower() == "rejected":
        return 0
    return asset_id


def lower_map() -> dict[str, str]:
    """
    Case-insensitive fallback: lowercase name -> canonical key. Canonical keys win over aliases
    when two names collide (e.g. "teleport": key Teleport; the exact alias "teleport" -> Teleporter
    still wins in IconAssets.resolve because exact aliases are checked before this table).
    """
    result: dict[str, str] = {}
    for key in ICONS:
        result.setdefault(key.lower(), key)
    for alias, key in ALIASES.items():
        result.setdefault(alias.lower(), key)
    return result


def render_config(assets: dict[str, int], sources: dict[str, str]) -> str:
    """The generated Luau module text (deterministic, StyLua-clean, one line per key)."""
    # StyLua's layout for a long union: first member on its own line, then "| member" lines.
    keys = "\n".join(("\t" if index == 0 else "\t| ") + f'"{key}"' for index, key in enumerate(ICONS))
    lines = [
        "--!strict",
        "--[[",
        "\tIconAssets — GENERATED by tools/ui/icons/icons.py (sync). Do not edit by hand.",
        "",
        "\tPurpose:",
        "\t\tThe rendered, 3D-looking UI icons (owner R9): HUD buttons, currencies, offers, rewards, game",
        "\t\tobjects and the ten area icons. Each key maps to one uploaded Image asset (512 x 512, transparent,",
        "\t\tglossy shading, thick dark outline). An empty `image` means \"not uploaded yet\" or \"moderation",
        "\t\trejected it\": UI/Kit/StudUI then draws its frame-built Glyphs fallback instead.",
        "",
        "\tSources / licence:",
        "\t\tMost icons are Microsoft Fluent Emoji 3D (github.com/microsoft/fluentui-emoji), MIT License,",
        "\t\tCopyright (c) Microsoft Corporation; outline, colour lift and composites by SellNukes. The rest",
        "\t\tare original Blender renders (tools/blender/ui_icons/render_icons.py). Full licence text and",
        "\t\tper-icon sources: assets/icons/LICENSE.md + assets/icons/sources.json; runbook: docs/icons.md.",
        "",
        "\tAPI:",
        "\t\tIconAssets.get(key)        -> IconEntry { image, size, category, source } (blank entry if unknown)",
        '\t\tIconAssets.image(key)      -> "rbxassetid://N" or nil (legacy helper used by StudUI / Toasts)',
        "\t\tIconAssets.Icons[key]      -> IconEntry       IconAssets.Ids[key] -> asset id (0 = none)",
        "\t\tIconAssets.Aliases[name]   -> key (legacy keys, MonetizationConfig product keys + icon names)",
        f"\t\tIconAssets.Categories[cat] -> ordered keys ({', '.join(CATEGORIES)})",
        "\tLookup order: exact key, exact alias, then case-insensitive (IconAssets.Lower), e.g. \"SHOP\".",
        "",
        "\tExample:",
        '\t\tlocal entry = IconAssets.get("Shop") -- also IconAssets.get("crown") -> the VIP icon',
        '\t\timageLabel.Image = entry.image -- "" until uploaded: show the fallback glyph then',
        "]]",
        "",
        "export type IconKey =",
        keys,
        "",
        "-- Entries are frozen (immutable), hence read-only properties.",
        "export type IconEntry = {",
        "\tread image: string,",
        "\tread size: Vector2,",
        "\tread category: string,",
        "\tread source: string,",
        "}",
        "",
        "-- Every icon is rendered at 512 x 512.",
        "local SIZE = Vector2.new(512, 512)",
        "",
        "--[[",
        "\tBuilds one frozen icon entry.",
        "\t@param id       uploaded Image asset id (0 = not uploaded / rejected -> image \"\")",
        '\t@param category "hud" | "currency" | "offer" | "reward" | "game" | "area" | "ui" | "event"',
        '\t@param source   "pack" (Fluent Emoji 3D) | "blender" (original render) | "composite"',
        '\tExample: entry(123, "hud", "pack").image --> "rbxassetid://123"',
        "]]",
        "local function entry(id: number, category: string, source: string): IconEntry",
        "\treturn table.freeze({",
        '\t\timage = if id > 0 then `rbxassetid://{id}` else "",',
        "\t\tsize = SIZE,",
        "\t\tcategory = category,",
        "\t\tsource = source,",
        "\t})",
        "end",
        "",
        "-- Returned for unknown keys so callers never index nil.",
        'local BLANK: IconEntry = entry(0, "", "")',
        "",
        "local IconAssets = {}",
        "",
        "-- Uploaded Image asset id per key (0 = not uploaded yet or moderation rejected).",
        "IconAssets.Ids = table.freeze({",
    ]
    lines += [f"\t{key} = {assets.get(key, 0)}," for key in ICONS]
    lines += [
        "}) :: { [string]: number }",
        "",
        "-- Entry per key: image content id + size + category + source kind.",
        "IconAssets.Icons = table.freeze({",
    ]
    lines += [f'\t{key} = entry({assets.get(key, 0)}, "{CATEGORY_OF[key]}", "{sources[key]}"),' for key in ICONS]
    lines += [
        "}) :: { [string]: IconEntry }",
        "",
        "-- Other names that resolve to a key: legacy keys, MonetizationConfig product keys and its",
        "-- lowercase `icon` names.",
        "IconAssets.Aliases = table.freeze({",
    ]
    lines += [f'\t{alias} = "{key}",' for alias, key in ALIASES.items()]
    lines += [
        "}) :: { [string]: string }",
        "",
        "-- Case-insensitive fallback: lowercase key / alias -> key (checked after exact matches).",
        "IconAssets.Lower = table.freeze({",
    ]
    lines += [f'\t["{lowered}"] = "{key}",' for lowered, key in sorted(lower_map().items())]
    lines += [
        "}) :: { [string]: string }",
        "",
        "-- Ordered keys per category (screens list icons in this order, e.g. the teleport list).",
        "IconAssets.Categories = table.freeze({",
    ]
    for category, keys_in in CATEGORIES.items():
        lines.append(f"\t{category} = table.freeze({{")
        lines += [f'\t\t"{key}",' for key in keys_in]
        lines.append("\t}),")
    lines += [
        "}) :: { [string]: { string } }",
        "",
        "--[[",
        "\tThe canonical key for `key` (itself, or the alias target), or nil when unknown.",
        '\tExample: IconAssets.resolve("DoubleCash") --> "x2Cash"',
        "]]",
        "function IconAssets.resolve(key: string): string?",
        "\tif IconAssets.Icons[key] ~= nil then",
        "\t\treturn key",
        "\tend",
        "\treturn IconAssets.Aliases[key] or IconAssets.Lower[string.lower(key)]",
        "end",
        "",
        "--[[",
        "\tThe icon entry for a key or alias; a blank entry (image \"\") for unknown keys.",
        '\tExample: IconAssets.get("Gems").image --> "rbxassetid://..." or ""',
        "]]",
        "function IconAssets.get(key: string): IconEntry",
        "\tlocal resolved = IconAssets.resolve(key)",
        "\tif resolved == nil then",
        "\t\treturn BLANK",
        "\tend",
        "\treturn IconAssets.Icons[resolved] or BLANK",
        "end",
        "",
        "--[[",
        "\tLegacy helper: the content id for a key or alias, or nil while it is not uploaded / unknown.",
        '\tExample: IconAssets.image("Gem") --> "rbxassetid://..." or nil',
        "]]",
        "function IconAssets.image(key: string): string?",
        "\tlocal image = IconAssets.get(key).image",
        '\treturn if image ~= "" then image else nil',
        "end",
        "",
        "return table.freeze(IconAssets)",
        "",
    ]
    return "\n".join(lines)


def command_sync(_args=None) -> int:
    """Regenerates the Luau config from the manifest + receipts (no network), then StyLua-formats it."""
    manifest = read_json(MANIFEST, {"icons": {}})
    every = catalog()
    assets = {name: receipt_asset(name, manifest) for name in ICONS}
    text = render_config(assets, {name: every[name]["kind"] for name in ICONS})
    if not CONFIG.exists() or CONFIG.read_text(encoding="utf-8") != text:
        atomic_write(CONFIG, text.encode())
        print(f"Wrote {CONFIG.relative_to(ROOT)} ({sum(1 for v in assets.values() if v)} / {len(ICONS)} icons mapped)")
    else:
        print(f"{CONFIG.relative_to(ROOT)} is up to date")
    return 0


def command_status(_args=None) -> int:
    """One line per icon: source kind, rendered bytes, uploaded asset and moderation."""
    manifest = read_json(MANIFEST, {"icons": {}})
    for name in ICONS:
        entry = manifest.get("icons", {}).get(name, {})
        receipt = read_json(RECEIPTS / f"{name}.json", {})
        stale = " (STALE: re-upload)" if receipt and receipt.get("sha256") != entry.get("sha256") else ""
        print(
            f"{name:13} {entry.get('source', '-'):9} png={entry.get('bytes', '-'):>7} "
            f"asset={receipt.get('assetId', 0):<16} moderation={receipt.get('moderation', '-')}{stale}"
        )
    return 0


def main() -> int:
    """CLI entry point (argparse sub-commands; see the module docstring)."""
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("fetch", help="download pinned pack sources (hash-checked)").set_defaults(handler=command_fetch)
    render = commands.add_parser("render", help="raw pass + outline + downsample + contact sheet")
    render.add_argument("--only", help="comma list of icon keys")
    render.set_defaults(handler=command_render)
    commands.add_parser("sheet", help="rebuild assets/icons/contact-sheet.png").set_defaults(handler=command_sheet)
    commands.add_parser("license", help="regenerate assets/icons/LICENSE.md").set_defaults(handler=command_license)
    upload = commands.add_parser("upload", help="upload new / changed icons, then sync")
    upload.add_argument("--user-id", required=True, type=int)
    upload.add_argument("--only", help="comma list of icon keys")
    upload.add_argument("--replace", help="comma list of keys (or 'all') whose previous upload may be retired")
    upload.add_argument("--dry-run", action="store_true")
    upload.set_defaults(handler=command_upload)
    commands.add_parser("moderation", help="refresh moderation states, then sync").set_defaults(handler=command_moderation)
    commands.add_parser("sync", help="regenerate src/shared/Config/IconAssets.luau").set_defaults(handler=command_sync)
    commands.add_parser("status", help="one line per icon").set_defaults(handler=command_status)
    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ToolError as error:
        sys.exit(f"icons: {error}")
    except subprocess.CalledProcessError:
        sys.exit("icons: Blender render failed (rerun the Blender command by hand to see its log)")
