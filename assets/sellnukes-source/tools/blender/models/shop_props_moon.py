"""
shop_props_moon.py — Moon Base (World 3, owner R70) props for the Shop's rotating ViewportFrames
(owner R39 "in the shop we should use real 3d models"). W1's ShopConfig Moon section maps the Moon
products `MoonRocksSmall` / `MoonRocksMedium` / `MoonRocksLarge` / `AstronautPack` to these keys,
exactly like Dino Valley uses `shop_props_dino.py` (spec 2026-10-31-r69-moon-lucky-juice-design.md
§2.6 / §2.7; owner W1b).

    Shop_MoonRocksSmall   "Bag of Moon Rocks": a little pile of three chunky faceted lilac moon rocks
                          (two side by side, one on top) and a pebble, crater dimples on every side, two
                          glowing cyan specks and one tiny cyan Neon sparkle.
    Shop_MoonRocksMedium  "Sack of Moon Rocks": a plump lilac-grey cloth sack with a frilled gathered top
                          and a gold rope tie, moon rocks spilling out of the top and resting at its foot,
                          a yellow star patch on its front AND back.
    Shop_MoonRocksLarge   "Crate of Moon Rocks": a white space-metal crate with slate edge frames and thin
                          cyan Neon stripes (front + back), heaped with nine moon rocks and three cut cyan
                          star shards, one Neon sparkle on top (the "jackpot" read).
    Shop_AstronautPack    one-time pack (Moon Rocks + Rocket Corgi pet + 2x boost): the Rocket Corgi — a
                          cute corgi head (pointy ears, cream blaze, big eyes, tongue) inside a clear Glass
                          bubble helmet with a white collar and gold band — standing on a lilac star crate.

Contract (identical to `shop_props.py`): Roblox space (studs, +Y up), PIVOT = ground centre under the
prop (every builder ends with `_recentre`: bounding box centred on X / Z, lowest point y = 0), FRONT
faces -Z. Props are ~1.8-3.2 studs tall and decorated front AND back because the shop turntable spins
them about +Y. Budgets: <= 2,000 triangles, <= 12 pieces, one colour per piece. StudsSmall on every main
surface, Smooth for tiny details, Glass (transparent) for the helmet bubble, Neon only for specks /
stripes / sparkles far below NeonMaxArea (6 studs^2, owner R19).

Kid rules (spec §2.1): cute, nothing scary — a happy corgi in a bubble helmet, candy lilac rocks.
Piece names avoid WorldFx words (Rocket, Glow, Core, Wheel, Fan, Crystal, Liquid, Swirl, ...), so
nothing here moves or emits a WorldFx light.

Rocks are low-poly ellipsoids (5 rings x 7 segments = 56 tris) whose vertices are pushed in / out by
a deterministic hash (no RNG: builds are reproducible and the upload content hash is stable).

Example (build + look):
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only Shop_MoonRocksSmall
    python3 tools/blender/contact_sheet.py --only Shop_MoonRocksSmall
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import Model
from snkit.shapes import box, cylinder, ellipsoid, revolve, ring_tube

from models._critter_kit import oriented_ellipsoid, plate, star_outline
from models.shop_props import _recentre

# ------------------------------------------------------------------------------------------------
# Moon shop palette (WorldsConfig Moon Rocks colour 196, 180, 255, lifted a little because the stud
# map darkens props ~10 %; Star Shards 120, 230, 255).
# ------------------------------------------------------------------------------------------------
ROCK_LILAC = (212, 198, 255)  # moon rocks (the currency look)
ROCK_LILAC_ALT = (184, 190, 255)  # every other rock: a bluer lilac so neighbours separate in the pile
CRATER = (132, 112, 214)  # crater dimples
SPECK_CYAN = (120, 230, 255)  # glowing specks / stripes / sparkles (Neon, tiny)
SHARD_CYAN = (110, 220, 255)  # cut star shards (StudsSmall: big enough to break the glow budget)
SACK_CLOTH = (204, 194, 236)  # the sack's moon-dust cloth
ROPE_GOLD = (240, 196, 92)  # sack tie, helmet band
PATCH_YELLOW = (255, 214, 50)  # star patches / crate stars
CRATE_WHITE = (236, 238, 248)  # space-metal crate body, helmet collar
CRATE_SLATE = (92, 98, 140)  # crate edge frames
CORGI_ORANGE = (252, 162, 72)
CORGI_CREAM = (255, 240, 214)
CORGI_PINK = (255, 150, 170)  # inner ears + tongue
INK = (36, 30, 44)  # eyes + nose
BUBBLE_GLASS = (200, 230, 255)  # helmet bubble (Glass, transparent)


def _hash01(*values: float) -> float:
    """A deterministic pseudo-random number in [0, 1) from a few numbers (no RNG anywhere)."""
    x = math.sin(sum(v * k for v, k in zip(values, (12.9898, 78.233, 37.719, 4.581)))) * 43758.5453
    return x - math.floor(x)


def _rock(piece, centre, radius: float, seed: int, squash=(1.08, 0.82, 0.94)) -> tuple:
    """
    One chunky faceted moon rock: a 5 x 7 ellipsoid (56 tris) bumped in / out per vertex by a hash of
    its direction (seed = shape), so every rock is a different lump with flat facets.
    @return the rock's radii (x, y, z) before bumps, for crater placement / stacking
    Example: radii = _rock(rocks, (0, 0.5, 0), 0.6, seed=3)
    """
    radii = (radius * squash[0], radius * squash[1], radius * squash[2])

    def deform(x: float, y: float, z: float):
        length = math.sqrt(x * x + y * y + z * z) or 1.0
        bump = 0.86 + 0.26 * _hash01(round(x / length, 3), round(y / length, 3), round(z / length, 3), seed)
        return (x * bump, y * bump, z * bump)

    ellipsoid(piece, centre, radii, rings=5, segments=7, deform=deform)
    return radii


def _craters(piece, centre, radii, seed: int, count: int = 3):
    """
    `count` crater dimples spread around a rock (front, back and sides, so every turntable angle sees
    some): flat dark-lilac discs lying on the surface (normal outward). ~28 tris each.
    """
    cx, cy, cz = centre
    for index in range(count):
        yaw = math.radians(360.0 * index / count + 40.0 * _hash01(seed, index, 2.1))
        lift = math.radians(-5.0 + 40.0 * _hash01(seed, index, 5.3))
        d = Vector((math.sin(yaw) * math.cos(lift), math.sin(lift), -math.cos(yaw) * math.cos(lift)))
        surface = Vector((cx + d.x * radii[0] * 0.95, cy + d.y * radii[1] * 0.95, cz + d.z * radii[2] * 0.95))
        size = min(radii) * (0.24 + 0.12 * _hash01(seed, index, 8.7))
        oriented_ellipsoid(piece, tuple(surface), (size, size, 0.05), normal=tuple(d), rings=3, segments=7)


def _speck(piece, centre, radii, direction, size: float = 0.07):
    """A tiny glowing cyan speck (Neon) sitting on a rock's surface along `direction`."""
    d = Vector(direction).normalized()
    p = Vector(centre) + Vector((d.x * radii[0], d.y * radii[1], d.z * radii[2])) * 0.97
    ellipsoid(piece, tuple(p), (size, size, size), rings=3, segments=6)


def _sparkle(piece, centre, size: float, thickness: float = 0.05):
    """
    Four-point sparkle star made of two crossed plates (faces Z and X), readable from every turntable
    angle. 56 tris. Neon only: keep size <= 0.3 (glow budget R19).
    """
    outline = star_outline(size, size * 0.3, points=4)
    plate(piece, outline, centre, (0, 0, -1), (0, 1, 0), thickness)
    plate(piece, outline, centre, (1, 0, 0), (0, 1, 0), thickness)


def _shard(piece, centre, size: float, normal, spin: float = 0.0):
    """
    A cut cyan star shard: a chunky 4-point star plate (thick, so it reads as a crystal, not a decal)
    standing on its tip in the heap, facing `normal`.
    """
    outline = star_outline(size, size * 0.42, points=4, rotate=90.0 + spin)
    plate(piece, outline, centre, normal, (0, 1, 0), size * 0.42)


def _rock_set(m, prefix: str = "Rocks"):
    """The shared rock pieces (two lilacs, craters, Neon specks) of a moon-rock prop."""
    return (
        m.piece(prefix, ROCK_LILAC, material="StudsSmall"),
        m.piece(f"{prefix}Alt", ROCK_LILAC_ALT, material="StudsSmall"),
        m.piece("Craters", CRATER, material="Smooth"),
        m.piece("Specks", SPECK_CYAN, material="Neon"),
    )


def _pile(m, layout, seed0: int = 0):
    """
    Drops a list of rocks: layout rows are (x, y, z, radius); rocks alternate lilac / bluer lilac,
    each gets craters, every third rock a glowing speck on its front and back.
    @return the top of the pile (highest rock top y)
    """
    rocks, alt, craters, specks = _rock_set(m)
    top = 0.0
    for index, (x, y, z, r) in enumerate(layout):
        piece = alt if index % 2 else rocks
        seed = seed0 + index
        radii = _rock(piece, (x, y, z), r, seed)
        _craters(craters, (x, y, z), radii, seed, count=3 if r > 0.45 else 2)
        if index % 3 == 0:
            _speck(specks, (x, y, z), radii, (0.4, 0.6, -0.7))
            _speck(specks, (x, y, z), radii, (-0.3, 0.5, 0.8))
        top = max(top, y + radii[1])
    return top


# ================================================================================================
# 1. Shop_MoonRocksSmall
# ================================================================================================


def build_moon_rocks_small():
    """A little pile: two rocks side by side, one on top, a pebble in front; specks + one sparkle."""
    m = Model(
        "Shop_MoonRocksSmall",
        "ground centre under the rock pile (lowest rock at y = 0); front faces -Z; shop viewport prop for "
        "the 'Bag of Moon Rocks' Moon Rocks pack; three chunky lilac moon rocks and a pebble",
        budget=2000,
    )
    layout = (
        (-0.56, 0.5, 0.06, 0.64),
        (0.58, 0.47, -0.04, 0.6),
        (0.02, 1.26, 0.0, 0.56),
        (0.36, 0.2, -0.78, 0.26),
    )
    top = _pile(m, layout, seed0=11)
    sparkle = m.piece("Sparkle", SPECK_CYAN, material="Neon")
    _sparkle(sparkle, (0.62, top + 0.42, -0.2), 0.22)
    _recentre(m)
    return m


# ================================================================================================
# 2. Shop_MoonRocksMedium
# ================================================================================================

SACK_PROFILE = [(0.0, 0.0), (0.66, 0.04), (0.98, 0.32), (1.06, 0.78), (0.96, 1.24), (0.7, 1.58), (0.42, 1.8), (0.36, 1.88)]


def build_moon_rocks_medium():
    """A plump frilled sack tied with gold rope, rocks spilling out of its top and at its foot."""
    m = Model(
        "Shop_MoonRocksMedium",
        "ground centre under the sack (lowest point at y = 0); front faces -Z; shop viewport prop for the "
        "'Sack of Moon Rocks' Moon Rocks pack; a frilled cloth sack overflowing with lilac moon rocks",
        budget=2000,
    )
    sack = m.piece("Sack", SACK_CLOTH, material="StudsSmall")
    rope = m.piece("Rope", ROPE_GOLD, material="Smooth")
    patch = m.piece("StarPatch", PATCH_YELLOW, material="Smooth")
    revolve(sack, SACK_PROFILE, center=(0, 0, 0), segments=14)
    # The frill: a flared cloth collar above the tie.
    revolve(sack, [(0.36, 1.86), (0.52, 1.98), (0.66, 2.1), (0.6, 2.16), (0.44, 2.04), (0.34, 1.94)], center=(0, 0, 0), segments=14, closed=True)
    ring_tube(rope, (0, 1.82, 0), 0.42, 0.12, 0.14, segments=14)
    # A rope bow hanging on the front.
    for side in (-1, 1):
        oriented_ellipsoid(rope, (side * 0.16, 1.74, -0.44), (0.16, 0.08, 0.05), normal=(side * 0.3, 0, -1), rings=3, segments=8)
    # Star patches front + back (on the sack's belly at y ~ 0.8, radius ~1.06).
    for normal, z in (((0, 0, -1), -1.07), ((0, 0, 1), 1.07)):
        plate(patch, star_outline(0.36, 0.17), (0, 0.84, z), normal, (0, 1, 0), 0.05)
    # Rocks spilling out of the open top + resting at the foot (front and back).
    layout = (
        (-0.2, 2.18, 0.08, 0.36),
        (0.24, 2.24, -0.06, 0.34),
        (0.02, 2.5, 0.02, 0.3),
        (-0.78, 0.28, -0.8, 0.32),
        (0.86, 0.26, -0.64, 0.28),
        (0.5, 0.28, 0.92, 0.3),
    )
    top = _pile(m, layout, seed0=23)
    sparkle = m.piece("Sparkle", SPECK_CYAN, material="Neon")
    _sparkle(sparkle, (0.5, top + 0.34, 0.0), 0.2)
    _recentre(m)
    return m


# ================================================================================================
# 3. Shop_MoonRocksLarge
# ================================================================================================

CRATE = (2.4, 1.1, 1.7)  # crate body (x, height, z)


def build_moon_rocks_large():
    """A white space crate (slate frames, cyan Neon stripes) heaped with rocks and cyan star shards."""
    m = Model(
        "Shop_MoonRocksLarge",
        "ground centre under the crate (lowest point at y = 0); front faces -Z; shop viewport prop for the "
        "'Crate of Moon Rocks' Moon Rocks pack; a space crate heaped with moon rocks and star shards",
        budget=2000,
    )
    crate = m.piece("Crate", CRATE_WHITE, material="StudsSmall")
    frame = m.piece("CrateFrame", CRATE_SLATE, material="StudsSmall")
    stripes = m.piece("Stripes", SPECK_CYAN, material="Neon")
    shards = m.piece("Shards", SHARD_CYAN, material="StudsSmall")
    w, h, d = CRATE
    box(crate, (0, h / 2, 0), (w, h, d), bevel=0.06)
    # Edge frames: four vertical posts + top / bottom rims (slate), proud of the walls.
    for x in (-w / 2, w / 2):
        for z in (-d / 2, d / 2):
            box(frame, (x, h / 2, z), (0.16, h + 0.04, 0.16), bevel=0.03)
    for y in (0.06, h - 0.02):
        box(frame, (0, y, -d / 2), (w + 0.04, 0.12, 0.12), bevel=0.02)
        box(frame, (0, y, d / 2), (w + 0.04, 0.12, 0.12), bevel=0.02)
        box(frame, (-w / 2, y, 0), (0.12, 0.12, d + 0.04), bevel=0.02)
        box(frame, (w / 2, y, 0), (0.12, 0.12, d + 0.04), bevel=0.02)
    # Thin cyan Neon stripes across the front and back walls (2.0 x 0.08 each: far under the budget).
    for z in (-d / 2 - 0.02, d / 2 + 0.02):
        box(stripes, (0, h * 0.5, z), (w - 0.5, 0.08, 0.04))
    # The heap: a ring of rocks on the rim + a raised middle (rows x, y, z, radius).
    rim = h + 0.12
    layout = (
        (-0.82, rim, -0.42, 0.42), (0.0, rim, -0.5, 0.44), (0.82, rim, -0.4, 0.4),
        (-0.84, rim, 0.44, 0.4), (0.04, rim, 0.5, 0.42), (0.86, rim, 0.42, 0.4),
        (-0.4, rim + 0.42, 0.0, 0.42), (0.42, rim + 0.4, 0.02, 0.4),
        (0.0, rim + 0.82, 0.0, 0.38),
    )
    top = _pile(m, layout, seed0=41)
    # Cut star shards poking out of the heap (front, back, side).
    _shard(shards, (-0.44, rim + 0.56, -0.62), 0.3, (0, 0, -1), spin=10.0)
    _shard(shards, (0.48, rim + 0.5, 0.64), 0.28, (0, 0, 1), spin=-12.0)
    _shard(shards, (1.06, rim + 0.3, 0.0), 0.24, (1, 0, 0), spin=6.0)
    sparkle = m.piece("Sparkle", SPECK_CYAN, material="Neon")
    _sparkle(sparkle, (0.3, top + 0.36, -0.1), 0.22)
    _recentre(m)
    return m


# ================================================================================================
# 4. Shop_AstronautPack
# ================================================================================================

HELMET_Y = 1.92  # bubble centre height (on the crate)
BUBBLE_R = 0.86


def build_astronaut_pack():
    """The Rocket Corgi: a corgi head in a Glass bubble helmet (white collar, gold band) on a star crate."""
    m = Model(
        "Shop_AstronautPack",
        "ground centre under the star crate (lowest point at y = 0); front faces -Z; shop viewport prop for "
        "the one-time Astronaut Pack; the Rocket Corgi pet's head in a bubble helmet on a lilac star crate",
        budget=2000,
    )
    crate = m.piece("StarCrate", ROCK_LILAC, material="StudsSmall")
    stars = m.piece("CrateStars", PATCH_YELLOW, material="Smooth")
    collar = m.piece("Collar", CRATE_WHITE, material="StudsSmall")
    band = m.piece("Band", ROPE_GOLD, material="Smooth")
    bubble = m.piece("Bubble", BUBBLE_GLASS, material="Glass", transparency=0.55)
    fur = m.piece("Fur", CORGI_ORANGE, material="StudsSmall")
    cream = m.piece("Blaze", CORGI_CREAM, material="StudsSmall")
    pink = m.piece("Pink", CORGI_PINK, material="Smooth")
    ink = m.piece("Ink", INK, material="Smooth")
    shine = m.piece("Shine", (255, 255, 255), material="Smooth")
    # The crate (1.5 x 0.9 x 1.5) with a star on every side wall.
    box(crate, (0, 0.45, 0), (1.5, 0.9, 1.5), bevel=0.08)
    for normal in ((0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0)):
        n = Vector(normal)
        plate(stars, star_outline(0.3, 0.14), tuple(Vector((0, 0.46, 0)) + n * 0.77), normal, (0, 1, 0), 0.04)
    # Helmet collar (white ring + gold band) sitting on the crate.
    revolve(collar, [(0.0, 0.9), (0.74, 0.9), (0.84, 0.98), (0.84, 1.18), (0.74, 1.26), (0.0, 1.26)], segments=20)
    ring_tube(band, (0, 1.1, 0), 0.85, 0.06, 0.12, segments=20)
    # The bubble (Glass): a sphere resting in the collar.
    ellipsoid(bubble, (0, HELMET_Y, 0), (BUBBLE_R, BUBBLE_R, BUBBLE_R), rings=10, segments=16)
    # The corgi head inside: round orange head, cream blaze + muzzle, two tall pointy ears.
    head_c = Vector((0, HELMET_Y - 0.08, 0))
    ellipsoid(fur, tuple(head_c), (0.5, 0.46, 0.46), rings=6, segments=10)
    ellipsoid(cream, tuple(head_c + Vector((0, -0.14, -0.26))), (0.32, 0.24, 0.26), rings=5, segments=8)
    for side in (-1, 1):
        ear = [(-0.16, 0.0), (0.16, 0.0), (0.03, 0.42)]
        base = head_c + Vector((side * 0.28, 0.32, 0.0))
        plate(fur, ear, tuple(base), (side * 0.25, 0, -1), (side * -0.35, 1, 0), 0.1)
        inner = [(-0.09, 0.05), (0.09, 0.05), (0.02, 0.3)]
        plate(pink, inner, tuple(base + Vector((side * 0.0, 0.0, -0.06))), (side * 0.25, 0, -1), (side * -0.35, 1, 0), 0.03)
    # Big eyes with white shines, a nose and a little pink tongue (front only: the face looks forward).
    for side in (-1, 1):
        eye = head_c + Vector((side * 0.18, 0.12, -0.41))
        oriented_ellipsoid(ink, tuple(eye), (0.08, 0.1, 0.05), normal=(side * 0.25, 0.1, -1), rings=4, segments=8)
        oriented_ellipsoid(shine, tuple(eye + Vector((side * 0.02, 0.04, -0.04))), (0.03, 0.03, 0.02), normal=(0, 0, -1), rings=3, segments=6)
    oriented_ellipsoid(ink, tuple(head_c + Vector((0, -0.08, -0.52))), (0.07, 0.05, 0.05), normal=(0, 0, -1), rings=3, segments=8)
    oriented_ellipsoid(pink, tuple(head_c + Vector((0.02, -0.25, -0.46))), (0.06, 0.07, 0.03), normal=(0, -0.3, -1), rings=3, segments=8)
    # The back of the head: a cream tail-of-blaze stripe so the back view still reads "corgi".
    oriented_ellipsoid(cream, tuple(head_c + Vector((0, 0.08, 0.42))), (0.12, 0.26, 0.05), normal=(0, 0.1, 1), rings=4, segments=8)
    # A tiny antenna with a ball on the helmet top (white stalk inside the collar colour, gold ball).
    cylinder(collar, (0, HELMET_Y + BUBBLE_R - 0.04, 0), (0, HELMET_Y + BUBBLE_R + 0.3, 0), 0.04, segments=6)
    ellipsoid(band, (0, HELMET_Y + BUBBLE_R + 0.36, 0), (0.09, 0.09, 0.09), rings=4, segments=8)
    _recentre(m)
    return m


BUILDERS = {
    "Shop_MoonRocksSmall": build_moon_rocks_small,
    "Shop_MoonRocksMedium": build_moon_rocks_medium,
    "Shop_MoonRocksLarge": build_moon_rocks_large,
    "Shop_AstronautPack": build_astronaut_pack,
}
