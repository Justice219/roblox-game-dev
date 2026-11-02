#!/usr/bin/env python3
"""
build_world_studs.py — generate SellNukes' tileable WORLD stud texture set (colour, normal, roughness).

Why:
    Every world surface in SellNukes (ground tiles, roads, walls, machines, nukes) carries the chunky
    "LEGO" stud look of the owner's references (docs/reference/missiles-vs-cities/*.png,
    docs/reference/sell-lemons/*.png): small raised rounded-square studs with a bevel that catches
    light on one side and shades on the other. Roblox's legacy `SurfaceType.Studs` only exists on
    primitive Parts, so we author our own texture set and apply it through ONE shared MaterialVariant
    (see docs/world-art.md for the experiment that picked MaterialVariant over SurfaceAppearance and
    Texture instances). The same three images serve every stud material in the game.

What it writes (default out dir: assets/world/studs/):
    studs_color.png      512x512 sRGB, near-white grey so `BasePart.Color` tints it to any colour.
                         Bevel lighting is baked in softly (light from the image's top-left) so studs
                         still read on low graphics quality where normal maps are skipped.
    studs_normal.png     512x512 tangent-space normal map, OpenGL convention (+G = image up), which
                         is what Roblox expects (MaterialVariant.NormalMap docs).
    studs_roughness.png  512x512 linear grey: stud tops slightly glossier than the gaps (toy plastic).
    texture.json         contract read by tools/ui/upload_world_studs.py: sizes, studs per tile,
                         per-file sha256 (the uploader refuses files whose hash does not match).

Layout:
    The 512 px tile holds a 2 x 2 grid of studs (256 px per stud cell). WorldMaterialConfig sets
    `StudsPerTile = 2` on Parts, so one stud cell = 1 stud, exactly like the references' legacy
    studs. Cells are fully periodic, so the tile repeats seamlessly in both directions.

Usage:
    python3 tools/ui/build_world_studs.py [--out assets/world/studs] [--size 512]

    Re-running with unchanged constants reproduces byte-identical PNGs (deterministic maths, no
    randomness, Pillow's PNG encoder with fixed options), so receipts stay valid.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]

# ------------------------------------------------------------------------------------------------
# Tunables. Units are "cell units": one stud cell spans [-0.5, 0.5] on both axes.
# ------------------------------------------------------------------------------------------------
CELLS_PER_TILE = 2  # studs per texture edge -> StudsPerTile = 2 gives 1 stud per world stud
STUD_HALF = 0.31  # half width of the stud's footprint (stud is 62 % of the cell)
STUD_CORNER = 0.07  # corner radius of the rounded square
BEVEL = 0.075  # width of the sloped rim between the gap and the stud top
TOP_LIFT = 0.04  # the stud top is very slightly pillowed toward its centre (catches a highlight)
GAP_AO_RANGE = 0.035  # how far the contact shadow spreads outside the stud base
GAP_AO_STRENGTH = 0.22  # darkness of that contact shadow (0 = none)
STUD_HEIGHT = 0.085  # physical stud height in cell units (bevel slope = height / BEVEL ~ 48 deg)
BASE_ALBEDO = 0.86  # flat gap colour; near-white so Part.Color tints the whole tile
TOP_ALBEDO = 0.93  # stud top colour (a touch lighter than the gaps, like moulded plastic)
BAKED_LIGHT = 0.38  # how much the baked top-left lighting brightens/darkens the bevels
ROUGH_BASE = 0.62  # roughness in the gaps
ROUGH_TOP = 0.48  # roughness on stud tops


def rounded_box_sdf(u: np.ndarray, v: np.ndarray, half: float, radius: float) -> np.ndarray:
    """
    Signed distance (cell units) to a rounded square centred at the origin.

    Negative inside, positive outside, zero on the outline. Standard Inigo Quilez formulation:
        q = |p| - (half - r); d = length(max(q, 0)) + min(max(q.x, q.y), 0) - r

    Example: rounded_box_sdf(np.array([0.0]), np.array([0.0]), 0.3, 0.05) -> [-0.3]
    """
    qx = np.abs(u) - (half - radius)
    qy = np.abs(v) - (half - radius)
    outside = np.sqrt(np.maximum(qx, 0.0) ** 2 + np.maximum(qy, 0.0) ** 2)
    inside = np.minimum(np.maximum(qx, qy), 0.0)
    return outside + inside - radius


def smoothstep(edge0: float, edge1: float, x: np.ndarray) -> np.ndarray:
    """Hermite 0..1 ramp (GLSL smoothstep) used for the bevel profile."""
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def build_fields(size: int) -> tuple[np.ndarray, np.ndarray]:
    """
    Compute the periodic height field H (0 = gap, ~1 = stud top) and the signed distance field.

    Pixel centres are sampled at (i + 0.5) so the pattern is symmetric and tiles without a seam.
    Returns (height, sdf), both float64 arrays shaped (size, size) indexed [row, col].
    """
    cell_px = size / CELLS_PER_TILE
    coords = (np.arange(size) + 0.5) / cell_px  # position in cells
    local = coords - np.floor(coords) - 0.5  # -0.5..0.5 inside each cell
    u = local[np.newaxis, :].repeat(size, axis=0)  # columns -> +x (image right)
    v = local[:, np.newaxis].repeat(size, axis=1)  # rows -> +y (image DOWN)
    sdf = rounded_box_sdf(u, v, STUD_HALF, STUD_CORNER)
    # Rim: rises from 0 at the outline (sdf = 0) to 1 at sdf = -BEVEL.
    rim = smoothstep(0.0, BEVEL, -sdf)
    # A gentle pillow on top so the flat face still varies a little under lighting.
    radial = np.sqrt(u * u + v * v) / (STUD_HALF * 1.4142)
    pillow = TOP_LIFT * (1.0 - np.clip(radial, 0.0, 1.0) ** 2)
    height = rim * (1.0 + pillow)
    return height, sdf


def normals_from_height(height: np.ndarray, size: int) -> np.ndarray:
    """
    Tangent-space normals (OpenGL: +X = image right, +Y = image UP, +Z = out of the surface).

    Uses periodic central differences (np.roll) so the edges of the tile match the opposite edge.
    H is 0..1 and scaled by STUD_HEIGHT (cell units); derivatives are per cell unit.
    """
    cell_px = size / CELLS_PER_TILE
    # Slope per cell unit: central difference per pixel times pixels per cell.
    d_dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5 * cell_px
    d_drow = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5 * cell_px
    d_dy_up = -d_drow  # rows grow downward; OpenGL +Y is up
    # Normal of the surface z = STUD_HEIGHT * H(x, y) is (-dz/dx, -dz/dy, 1), normalised below.
    nx = -d_dx * STUD_HEIGHT
    ny = -d_dy_up * STUD_HEIGHT
    nz = np.ones_like(nx)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack((nx / length, ny / length, nz / length), axis=-1)


def build_maps(size: int) -> dict[str, Image.Image]:
    """
    Build the three PIL images from the shared height/SDF fields.

    Colour = albedo (gap vs top) * baked directional light on the bevels * contact shadow.
    The baked light direction is image top-left (so bevels facing up-left brighten, down-right
    darken), matching the classic Roblox stud look. Values are clamped to [0, 1] then sRGB-encoded
    simply by quantising (the albedo constants are already chosen as display values).
    """
    height, sdf = build_fields(size)
    normal = normals_from_height(height, size)
    # Light from image top-left, slightly toward the viewer. In OpenGL tangent space top = +Y.
    light = np.array([-0.55, 0.55, 0.63])
    light = light / np.linalg.norm(light)
    flat = light[2]  # dot(flat normal, light)
    shade = normal @ light - flat  # 0 on flat areas, +/- on bevels
    albedo = BASE_ALBEDO + (TOP_ALBEDO - BASE_ALBEDO) * np.clip(height, 0.0, 1.0)
    # Contact shadow ring just outside the stud base (sdf > 0, decays with distance).
    ao = 1.0 - GAP_AO_STRENGTH * np.exp(-np.maximum(sdf, 0.0) / GAP_AO_RANGE) * (sdf > 0)
    colour = np.clip(albedo * (1.0 + BAKED_LIGHT * shade) * ao, 0.0, 1.0)
    rgb = (colour * 255.0 + 0.5).astype(np.uint8)
    colour_img = Image.fromarray(np.stack((rgb, rgb, rgb), axis=-1), "RGB")
    encoded = ((normal * 0.5 + 0.5) * 255.0 + 0.5).clip(0, 255).astype(np.uint8)
    normal_img = Image.fromarray(encoded, "RGB")
    rough = ROUGH_BASE + (ROUGH_TOP - ROUGH_BASE) * np.clip(height, 0.0, 1.0)
    rough_px = (rough * 255.0 + 0.5).astype(np.uint8)
    rough_img = Image.fromarray(np.stack((rough_px, rough_px, rough_px), axis=-1), "RGB")
    return {"color": colour_img, "normal": normal_img, "roughness": rough_img}


def save_png(image: Image.Image, path: Path) -> str:
    """Save deterministically (no metadata, fixed compression) and return the file's sha256."""
    image.save(path, format="PNG", optimize=False, compress_level=9)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    """Generate, verify tileability, and write the texture contract next to the PNGs."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--out", type=Path, default=ROOT / "assets/world/studs")
    parser.add_argument("--size", type=int, default=512, choices=(256, 512, 1024))
    args = parser.parse_args()
    out: Path = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    maps = build_maps(args.size)
    # Self-check: a periodic field must have matching first/last columns after one roll.
    colour = np.asarray(maps["color"], dtype=np.int16)
    seam = int(np.abs(colour[:, 0] - colour[:, -1]).max())
    if seam > 40:
        raise SystemExit(f"stud tile is not periodic (edge delta {seam}); check CELLS_PER_TILE")
    files = {}
    for kind, image in maps.items():
        name = f"studs_{kind}.png"
        files[kind] = {"file": name, "sha256": save_png(image, out / name)}
    contract = {
        "width": args.size,
        "height": args.size,
        "cellsPerTile": CELLS_PER_TILE,
        "files": files,
        "note": "Generated by tools/ui/build_world_studs.py; upload with tools/ui/upload_world_studs.py",
    }
    (out / "texture.json").write_text(json.dumps(contract, indent=2, sort_keys=True) + "\n")
    print(f"[studs] wrote {', '.join(f['file'] for f in files.values())} -> {out}")


if __name__ == "__main__":
    main()
