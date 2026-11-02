"""
dino_area02.py — Dino Valley area D2 "Fern Market" models (W6 art-d12, owner R57; spec
2026-10-31-world2-design §2 / §16): a market stall under a giant leaf awning where pebble nukes are
sold to the dinosaurs ("Fresh Pebble Nukes! Roar-some prices!").

    D2_Floor         lot with a sandy market square + flagstones and a path from the arch      base
    D2_EntryArch     "FERN MARKET" arch on lashed bamboo posts, thatch board                    base
    D2_Grove         palms with coconuts, banana plants, berry bushes, ferns, boulders (L / R)  base
    D2_Huts          two round thatched market huts framing the back of the square (L / R)    base
    D2_ShellCounter  the producer: log-topped stone counter trimmed with shells, pebble nukes   D2_ShellCounter
                     on leaf plates, a price slate
    D2_LeafAwning    four bamboo poles carrying three giant overlapping leaves                 D2_LeafAwning
    D2_CoconutTill   coconut-shell till with a bone lever and a stone drawer (on the counter) D2_CoconutTill
    D2_BerryBaskets  three woven baskets heaped with berries (placed 2x)                       D2_BerryBaskets
    D2_TotemSign     carved totem of three friendly dino faces under a double-sided "NUKES!"   D2_TotemSign
                     board with leaf wings (tall)
    D2_MammothFan    a baby woolly mammoth sitting up, its big `Ears` spread like an           D2_MammothFan
                     oscillating desk fan (WorldFx `Ears` row: yaw oscillation, see below)
    D2_PicnicLogs    stump table with a leaf plate of berries + two log benches (placed 4x)    D2_PicnicLogs
    D2_StegoSally    the Manager: a lilac stegosaurus in a teal market apron and a straw sun   D2_StegoSally
                     hat, rounded back plates; R30 rig groups (tail + plates ride the Torso)
    D2_BambooFence   16-stud bamboo fence run (placed 12x)                                    D2_BambooFence

Placement: src/shared/Config/Worlds/Dino/Layouts/Area02.luau (slot-local frame, docs/areas-art.md).
SLOT-ORIGIN models (D2_Floor, D2_Grove) use the slot origin as pivot (identity cf). Stall models
(counter, awning, till) share the STALL pivot: ground centre of the counter, customers on -Z,
counter top y = COUNTER_TOP. Every other model is pivoted at its own ground centre, front -Z.

WorldFx (W10): D2_MammothFan `Ears` = one piece holding both ears, symmetric about the head's
vertical axis (its box centre sits on that axis). Suggested row: Ears = { motion = "oscillate",
axis = "Y", amplitude = 14, period = 1.6 } — the ear pair sweeps left / right like a desk fan.
Shared helpers come from models/dino_area01.py.
"""

from __future__ import annotations

import math

from mathutils import Vector

from models._critter_kit import eyes, oriented_ellipsoid, plate, smile, tube
from models.area01 import LOT_TOP, SLOT_PIVOT, sign_text, text_cells
from models.area04 import _hash
from models.dino_area01 import (
    AMBER_GLOW,
    BAMBOO,
    BARK,
    BONE,
    FERN,
    FERN_DARK,
    INK,
    JUNGLE_FLOOR,
    LAVA,
    LOG,
    LOG_END,
    MOSS,
    SAND,
    SLOT_D,
    SLOT_W,
    STONE,
    STONE_DARK,
    STONE_WARM,
    THATCH,
    boulder,
    dino_arch,
    dino_biped,
    dino_bones,
    fern,
    log,
    palm,
    pebble_nuke,
)
from snkit.core import Model
from snkit.kit import block, disc
from snkit.shapes import cylinder, ellipsoid, extrude_outline, prism, revolve, rot_x, rot_y, rot_z

COUNTER_TOP = 3.3  # counter top above the stall pivot
STALL_PIVOT = "stall pivot: ground centre of the counter; customers on -Z; counter top y = 3.3"
SHELL_PINK = (255, 178, 170)
SHELL_CREAM = (255, 230, 196)
BERRY_RED = (226, 60, 80)
BERRY_BLUE = (90, 110, 230)
TEAL = (52, 184, 172)
LILAC = (186, 150, 236)
PLATE_ORANGE = (255, 150, 60)
MAMMOTH = (156, 102, 66)
MAMMOTH_LIGHT = (200, 150, 110)
STRAW = (240, 206, 120)


# ------------------------------------------------------------------------------------------------
# Base (slot origin pivot)
# ------------------------------------------------------------------------------------------------

PLAZA_X = 24.0  # market square half width
PLAZA_Z0, PLAZA_Z1 = 18.0, 54.0
PATH_HALF = 4.5


def _plaza_outline():
    """Market square with rounded corners + the path stub down to the arch, as one outline (x, z)."""
    r = 5.0
    pts = [(-PATH_HALF, 0.0), (-PATH_HALF, PLAZA_Z0)]
    corners = (
        (-PLAZA_X + r, PLAZA_Z0 + r, 270, 180),
        (-PLAZA_X + r, PLAZA_Z1 - r, 180, 90),
        (PLAZA_X - r, PLAZA_Z1 - r, 90, 0),
        (PLAZA_X - r, PLAZA_Z0 + r, 0, -90),
    )
    for cx, cz, a0, a1 in corners:
        for k in range(5):
            a = math.radians(a0 + (a1 - a0) * k / 4)
            pts.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    pts += [(PATH_HALF, PLAZA_Z0), (PATH_HALF, 0.0)]
    return pts


def build_floor():
    """Jungle lot with a sandy market square (+0.06), flagstones (+0.12) and moss patches (+0.1)."""
    m = Model("D2_Floor", SLOT_PIVOT, budget=2000)
    ground = m.piece("Ground", JUNGLE_FLOOR)
    sand = m.piece("Square", SAND)
    flags = m.piece("Flagstones", STONE_WARM)
    moss = m.piece("MossPatches", MOSS)
    block(ground, (0, LOT_TOP / 2, SLOT_D / 2), (SLOT_W, LOT_TOP, SLOT_D), bevel=0.1)
    extrude_outline(sand, _plaza_outline(), LOT_TOP - 0.04, LOT_TOP + 0.06)
    # Flagstones: irregular hexagons on a loose grid inside the square, never touching each other.
    k = 0
    for gz in range(5):
        for gx in range(6):
            x = -18.0 + gx * 7.2 + (2.0 if gz % 2 else 0.0) + (_hash(gx, gz) - 0.5) * 1.6
            z = 22.0 + gz * 7.0 + (_hash(gz, gx + 9) - 0.5) * 1.4
            if abs(x) > PLAZA_X - 3.5 or (abs(x) < 9.0 and 36.0 < z < 46.0):
                continue  # keep clear of the square's edge and the stall footprint
            r = 1.3 + 0.5 * _hash(k, 5)
            outline = [(x + r * math.cos(2 * math.pi * i / 6 + _hash(k, 7)), z + r * math.sin(2 * math.pi * i / 6 + _hash(k, 7))) for i in range(6)]
            extrude_outline(flags, outline, LOT_TOP + 0.02, LOT_TOP + 0.12)
            k += 1
    # Path stepping slabs from the arch.
    for i, z in enumerate((4.0, 9.0, 14.0)):
        disc(flags, ((_hash(i, 3) - 0.5) * 1.5, LOT_TOP + 0.02, z), 1.2, 0.1, segments=6, bevel=0.03)
    # Moss patches outside the square (clear of the pad strip z < 16 and the picnic spots).
    for i, (x, z, r) in enumerate(((-40, 34, 4.0), (40, 34, 4.0), (-34, 60, 3.6), (34, 60, 3.6), (-12, 60, 3.0), (12, 61, 3.0))):
        outline = []
        for kk in range(8):
            a = 2 * math.pi * kk / 8 + _hash(i, 2)
            rr = r * (0.8 + 0.35 * _hash(i * 7 + kk, 4))
            outline.append((x + rr * math.cos(a), z + rr * math.sin(a)))
        extrude_outline(moss, outline, LOT_TOP - 0.04, LOT_TOP + 0.1)
    return m


def build_arch():
    """FERN MARKET arch: lashed bamboo posts, a dark-wood board with bright fern-green letters."""
    return dino_arch(
        "D2_EntryArch",
        ["FERN", "MARKET"],
        stone=BAMBOO,
        stone_dark=(150, 160, 70),
        board=(118, 78, 50),
        frame=THATCH,
        letters=(176, 244, 120),
        post_style="bamboo",
    )


def banana_plant(stem, leaves, base, height=4.0, seed=0, count=5):
    """Banana / elephant-ear plant: short stalks with big paddle leaves arching outward."""
    bx, by, bz = base
    for i in range(count):
        a = 2 * math.pi * (i + 0.4 * _hash(seed, i)) / count
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        side = Vector((-d.z, 0.0, d.x))
        h = height * (0.7 + 0.4 * _hash(seed + 1, i))
        root = Vector((bx, by, bz))
        top = root + Vector((0, h, 0)) + d * 0.8
        cylinder(stem, tuple(root), tuple(top), 0.16, segments=5)
        tip = top + d * 3.2 + Vector((0, -0.9, 0))
        mid = top + d * 1.6 + Vector((0, 0.35, 0))
        outline = [top + side * 0.2, mid + side * 1.05, tip, mid - side * 1.05, top - side * 0.2]
        normal = side.cross((tip - top).normalized()).normalized()
        prism(leaves, [tuple(p) for p in outline], tuple(normal), 0.09)


def berry_bush(bush, berries, base, radius=1.5, seed=0):
    """Round bush (two lumpy blobs) dotted with berries."""
    bx, by, bz = base
    boulder(bush, (bx, by + radius * 0.7, bz), (radius, radius * 0.8, radius * 0.9), seed=seed, rings=4, segments=8, lump=0.1)
    boulder(bush, (bx + radius * 0.6, by + radius * 0.5, bz - radius * 0.3), (radius * 0.6,) * 3, seed=seed + 1, rings=4, segments=7, lump=0.1)
    for k in range(6):
        a = 2 * math.pi * k / 6 + _hash(seed, k)
        y = by + radius * (0.55 + 0.5 * _hash(seed + 2, k))
        rr = radius * 0.92 * math.sqrt(max(0.2, 1 - ((y - by - radius * 0.7) / (radius * 0.8)) ** 2))
        ellipsoid(berries, (bx + rr * math.cos(a), y, bz + rr * 0.95 * math.sin(a)), (0.2, 0.2, 0.2), rings=3, segments=5)


def build_grove():
    """
    Jungle frame of the market (slot pivot): palms with coconuts at the back and sides, banana
    plants along the back, berry bushes by the pad strip ends, a few boulders. Every piece is split
    -X ("L") / +X ("R") so no piece's box spans the stall (owner R31 / R32).
    """
    m = Model("D2_Grove", SLOT_PIVOT, budget=4000)
    trunks = {-1: m.piece("TrunksL", BARK), 1: m.piece("TrunksR", BARK)}
    leaves = {-1: m.piece("LeavesL", FERN), 1: m.piece("LeavesR", FERN)}
    plants = {-1: m.piece("BananaL", FERN_DARK), 1: m.piece("BananaR", FERN_DARK)}
    bush = {-1: m.piece("BushL", (70, 160, 70)), 1: m.piece("BushR", (70, 160, 70))}
    berries = m.piece("Berries", BERRY_RED, material="Smooth")
    nuts = m.piece("Coconuts", (130, 86, 54))
    rocks = m.piece("Rocks", STONE)
    for k, (x, z, h) in enumerate(((-45.0, 60.0, 12.0), (-34.0, 65.0, 10.0), (45.0, 59.0, 11.5), (34.0, 65.5, 10.5), (-46.0, 22.0, 9.5), (46.0, 22.0, 10.0))):
        side = -1 if x < 0 else 1
        palm(trunks[side], leaves[side], (x, LOT_TOP - 0.1, z), height=h, seed=k + 11, nuts=nuts if k < 4 else None)
    for k, (x, z) in enumerate(((-40.0, 50.0), (-9.0, 62.0), (40.0, 50.0), (9.0, 62.0))):
        side = -1 if x < 0 else 1
        # Stems share the low banana piece, NOT the tall palm-trunk piece: a trunk box reaching
        # in to the stems at x +-9 walled in the stall up to y 12.6 and left the producer
        # billboard no readable spot (W10b, owner R31 / R32, tests/billboard-clearance.luau).
        banana_plant(plants[side], plants[side], (x, LOT_TOP, z), height=3.6, seed=30 + k)
    for k, (x, z) in enumerate(((-29.0, 18.0), (29.0, 18.0), (-44.0, 36.0), (44.0, 36.0))):
        side = -1 if x < 0 else 1
        berry_bush(bush[side], berries, (x, LOT_TOP - 0.05, z), radius=1.5, seed=40 + k)
    for k, (x, z, r) in enumerate(((-30.0, 52.0, 1.3), (30.0, 52.0, 1.2))):
        boulder(rocks, (x, LOT_TOP + r * 0.72, z), (r * 1.3, r, r * 1.1), seed=60 + k)
    ferns = {-1: m.piece("FernsL", (64, 150, 64)), 1: m.piece("FernsR", (64, 150, 64))}
    for k, (x, z) in enumerate(((-27.0, 31.0), (27.0, 31.0), (-26.0, 50.0), (26.0, 50.0), (-48.0, 46.0), (48.0, 46.0))):
        side = -1 if x < 0 else 1
        fern(ferns[side], (x, LOT_TOP, z), size=1.0 + 0.2 * _hash(k, 6), seed=70 + k, fronds=5)
    return m


HUT_X, HUT_Z = 22.0, 60.0  # hut centres (slot x = +-HUT_X)
HUT_R = 4.0  # wall radius


def build_huts():
    """
    Two round market huts behind the square (slot pivot; centres x +-22, z 60): sandy mud walls
    with a log base ring, a dark doorway and two round windows facing the square (-Z), a conical
    thatch roof with a bound top knot and a cartoon bone on the peak. Pieces split L / R (R31).
    """
    m = Model("D2_Huts", SLOT_PIVOT + "; huts at x +-22, z 60 (wall radius 4)", budget=2600)
    for sx, side in ((-1, "L"), (1, "R")):
        wall = m.piece(f"Walls{side}", (226, 196, 150))
        roof = m.piece(f"Thatch{side}", THATCH)
        band = m.piece(f"Bands{side}", (196, 150, 74))
        dark = m.piece(f"Doors{side}", (70, 52, 44), material="Smooth")
        cx = sx * HUT_X
        base = (cx, LOT_TOP, HUT_Z)
        cylinder(wall, base, (cx, LOT_TOP + 4.2, HUT_Z), HUT_R, segments=12)
        cylinder(band, (cx, LOT_TOP, HUT_Z), (cx, LOT_TOP + 0.7, HUT_Z), HUT_R + 0.25, segments=12)
        # Roof: a cone overhanging the wall, a binding band near the top and a top knot.
        revolve(roof, [(0.0, 0.0), (HUT_R + 1.6, 0.0), (HUT_R + 1.4, 0.4), (0.9, 4.4), (0.0, 4.9)], center=(cx, LOT_TOP + 3.9, HUT_Z), segments=12)
        cylinder(band, (cx, LOT_TOP + 3.9 + 3.55, HUT_Z), (cx, LOT_TOP + 3.9 + 3.95, HUT_Z), 1.25, segments=10)
        # Doorway (front, facing the square) + round windows either side, proud of the wall.
        door_z = HUT_Z - HUT_R - 0.02
        outline = [(cx - 1.1, LOT_TOP + 0.7), (cx + 1.1, LOT_TOP + 0.7), (cx + 1.1, LOT_TOP + 2.4), (cx + 0.6, LOT_TOP + 3.0), (cx - 0.6, LOT_TOP + 3.0), (cx - 1.1, LOT_TOP + 2.4)]
        prism(dark, [(x, y, door_z) for x, y in outline], (0, 0, 1), 0.2)
        for wx in (-2.4, 2.4):
            a = math.asin(wx / HUT_R)
            n = (math.sin(a), 0.0, -math.cos(a))
            c = (cx + HUT_R * math.sin(a) * 1.005, LOT_TOP + 2.6, HUT_Z - HUT_R * math.cos(a) * 1.005)
            oriented_ellipsoid(dark, c, (0.55, 0.55, 0.1), normal=n, rings=3, segments=8)
    from models.dino_area01 import bone

    bone(band, (-HUT_X - 0.9, LOT_TOP + 9.0, HUT_Z), (-HUT_X + 0.9, LOT_TOP + 9.0, HUT_Z), 0.16, knob=0.26, segments=6)
    bone(m.pieces["BandsR"], (HUT_X - 0.9, LOT_TOP + 9.0, HUT_Z), (HUT_X + 0.9, LOT_TOP + 9.0, HUT_Z), 0.16, knob=0.26, segments=6)
    return m


# ------------------------------------------------------------------------------------------------
# Stall (stall pivot)
# ------------------------------------------------------------------------------------------------


def shell(piece, center, size, facing=(0, 0, -1), seed=0):
    """Cartoon scallop shell: a fan of 5 rounded ribs (squashed ellipsoids) + a hinge nub."""
    cx, cy, cz = center
    n = Vector(facing).normalized()
    up = Vector((0, 1, 0))
    side = up.cross(n).normalized()
    for k in range(5):
        a = math.radians(-60 + 30 * k)
        d = up * math.cos(a) + side * math.sin(a)
        c = Vector(center) + d * size * 0.45
        oriented_ellipsoid(piece, tuple(c), (size * 0.17, size * 0.5, size * 0.12), normal=tuple(n), up=tuple(d), rings=3, segments=6)
    oriented_ellipsoid(piece, (cx, cy - size * 0.05, cz), (size * 0.22, size * 0.16, size * 0.14), normal=tuple(n), rings=3, segments=6)


def build_shell_counter():
    """
    The Fern Market producer: a 14-wide counter of stacked warm stones with a thick log top, a row
    of pink / cream shells along its front, three pebble nukes on leaf plates on the top (small amber
    Neon bands, one piece each, R19) and a little slate with a bone price tag.
    """
    m = Model("D2_ShellCounter", STALL_PIVOT, budget=3000)
    stone = m.piece("Stones", STONE_WARM)
    dark = m.piece("StonesDark", STONE)
    top = m.piece("LogTop", LOG)
    ends = m.piece("LogEnds", LOG_END)
    pink = m.piece("ShellsPink", SHELL_PINK, material="Smooth")
    cream = m.piece("ShellsCream", SHELL_CREAM, material="Smooth")
    leaf = m.piece("LeafPlates", FERN)
    nstone = m.piece("PebbleStone", (226, 206, 168), material="StudsSmall")
    fins = m.piece("PebbleFins", STONE_DARK, material="StudsSmall")
    slate = m.piece("Slate", (70, 74, 80))
    tag = m.piece("Tag", BONE, material="Smooth")
    # Stone body: two courses of rounded stones (front face z -1.3), log top over it.
    for k in range(5):
        x = -5.6 + k * 2.8
        block(stone if k % 2 == 0 else dark, (x, 0.85, 0.0), (2.75, 1.7, 2.6), bevel=0.3)
    for k in range(4):
        x = -4.2 + k * 2.8
        block(dark if k % 2 == 0 else stone, (x, 2.35, 0.05), (2.75, 1.3, 2.45), bevel=0.3)
    for sx in (-1, 1):
        block(stone, (sx * 6.25, 2.35, 0.05), (1.4, 1.3, 2.45), bevel=0.25)
    # Log top: two half-buried logs side by side reading as a thick plank (top y = COUNTER_TOP).
    for z in (-0.65, 0.65):
        log(top, (-7.2, COUNTER_TOP - 0.62, z), (7.2, COUNTER_TOP - 0.62, z), 0.66, segments=8, ends=ends)
    # Shells along the front of the stones (proud of the stone face).
    for k in range(7):
        x = -5.4 + k * 1.8
        shell(pink if k % 2 == 0 else cream, (x, 1.5 + 0.35 * (k % 2), -1.42), 0.8, seed=k)
    # Leaf plates + pebble nukes on top (one Neon band piece each).
    for k, x in enumerate((-4.5, -1.6, 1.3)):
        prism(leaf, [(x - 1.0, COUNTER_TOP + 0.05, -0.2), (x, COUNTER_TOP + 0.05, -1.0), (x + 1.0, COUNTER_TOP + 0.05, -0.2), (x, COUNTER_TOP + 0.05, 0.7)], (0, 1, 0), 0.1)
        band = m.piece(f"PebbleBand{'ABC'[k]}", AMBER_GLOW, material="Neon")
        pebble_nuke(nstone, band, fins, (x, COUNTER_TOP + 0.1, -0.2), height=1.6, segments=8)
    # Price slate on a little easel at the right end (bone tag hanging from it).
    block(slate, (5.6, COUNTER_TOP + 0.75, 0.3), (1.8, 1.3, 0.16), bevel=0.05, rot=rot_x(-12))
    cylinder(tag, (5.6, COUNTER_TOP + 0.15, -0.05), (5.6, COUNTER_TOP + 0.1, 0.5), 0.07, segments=5)
    from models.dino_area01 import bone

    bone(tag, (5.15, COUNTER_TOP + 0.95, 0.12), (6.05, COUNTER_TOP + 0.95, 0.12), 0.08, knob=0.13, segments=6)
    return m


def build_leaf_awning():
    """
    Four bamboo poles (front pair 8 tall, back pair 9.5) carrying three giant leaves that overlap
    like shingles, each at its own height and tilt (R18: no shared planes), midribs on top.
    """
    m = Model("D2_LeafAwning", STALL_PIVOT, budget=1800)
    poles = m.piece("Poles", BAMBOO)
    rings = m.piece("Rings", (150, 160, 70))
    leaf_a = m.piece("LeafA", FERN)
    leaf_b = m.piece("LeafB", FERN_DARK)
    ribs = m.piece("Ribs", (190, 230, 120), material="Smooth")
    for sx in (-1, 1):
        for z, h in ((-2.4, 8.0), (4.4, 9.6)):
            cylinder(poles, (sx * 8.5, 0.0, z), (sx * 8.5, h, z), 0.3, segments=7)
            for y in (2.5, 5.0, 7.5):
                if y < h - 0.4:
                    cylinder(rings, (sx * 8.5, y - 0.09, z), (sx * 8.5, y + 0.09, z), 0.36, segments=7)
    # Cross bars on top of the poles (front + back) that the leaves rest on.
    for z, h in ((-2.4, 8.0), (4.4, 9.6)):
        cylinder(poles, (-9.2, h - 0.2, z), (9.2, h - 0.2, z), 0.26, segments=6)
    # Three leaves: pointed ovals spanning front -> back, tilted down toward the road.
    for k, (x, lift, piece) in enumerate(((-5.6, 0.0, leaf_a), (0.0, 0.35, leaf_b), (5.6, 0.0, leaf_a))):
        pts = []
        steps = 10
        for i in range(steps):
            t = 2 * math.pi * i / steps
            lx = 4.3 * math.sin(t) * (1.0 - 0.25 * max(0.0, math.cos(t)))
            lz = 1.0 + 4.9 * math.cos(t)
            # Slope: y rises from the road side (z -3.9) to the back (z 5.9).
            y = 7.95 + 0.17 * (lz + 3.9) + lift + 0.12 * k
            pts.append((x + lx, y, lz))
        normal = Vector((0.0, 1.0, -0.17)).normalized()
        prism(piece, pts, tuple(normal), 0.14)
        a = Vector((x, 7.95 + lift + 0.12 * k + 0.12, -3.6))
        b = Vector((x, 7.95 + 0.17 * 9.6 + lift + 0.12 * k + 0.12, 5.6))
        cylinder(ribs, tuple(a), tuple(b), 0.08, segments=5)
    return m


def build_coconut_till():
    """Coconut-shell till: a half coconut on a stone drawer, a bone crank lever and a tiny shell bell."""
    m = Model("D2_CoconutTill", "bottom centre (on the counter top); front -Z", budget=900)
    shell_p = m.piece("Coconut", (128, 84, 52))
    meat = m.piece("CoconutMeat", (250, 244, 228), material="Smooth")
    drawer = m.piece("Drawer", STONE_WARM)
    lever = m.piece("Lever", BONE, material="StudsSmall")
    block(drawer, (0, 0.35, 0), (1.6, 0.7, 1.3), bevel=0.15)
    block(drawer, (0, 0.35, -0.7), (0.5, 0.18, 0.12), bevel=0.04)
    revolve(shell_p, [(0.0, 0.0), (0.72, 0.05), (0.78, 0.45), (0.72, 0.55)], center=(0, 0.7, 0), segments=10)
    disc(meat, (0, 1.25, 0), 0.64, 0.06, segments=10, bevel=0.02)
    from models.dino_area01 import bone

    bone(lever, (0.85, 0.95, 0.1), (1.25, 1.75, 0.1), 0.07, knob=0.12, segments=6)
    return m


def build_berry_baskets():
    """Three woven baskets (thatch with darker weave bands) heaped with red and blue berries."""
    m = Model("D2_BerryBaskets", "ground centre of the group; front -Z", budget=1300)
    wicker = m.piece("Wicker", THATCH)
    weave = m.piece("Weave", (196, 150, 74))
    red = m.piece("BerriesRed", BERRY_RED, material="Smooth")
    blue = m.piece("BerriesBlue", BERRY_BLUE, material="Smooth")
    for k, (x, z, r, h) in enumerate(((-1.4, 0.2, 1.0, 1.2), (1.2, -0.3, 0.9, 1.0), (0.1, 1.4, 0.85, 1.5))):
        revolve(wicker, [(0.0, 0.0), (r * 0.8, 0.0), (r, h * 0.6), (r * 1.05, h)], center=(x, 0, z), segments=10)
        for y in (h * 0.3, h * 0.7):
            cylinder(weave, (x, y - 0.06, z), (x, y + 0.06, z), r * (0.86 + 0.18 * y / h) + 0.04, segments=10)
        piece = red if k % 2 == 0 else blue
        for i in range(7):
            a = 2 * math.pi * i / 7
            rr = r * 0.55 * (0.4 + 0.6 * _hash(k, i))
            ellipsoid(piece, (x + rr * math.cos(a), h + 0.05 + 0.1 * _hash(i, k), z + rr * math.sin(a)), (0.22, 0.22, 0.22), rings=4, segments=6)
        ellipsoid(piece, (x, h + 0.25, z), (0.24, 0.24, 0.24), rings=4, segments=6)
    return m


def _totem_face(wood, paint, eyes_p, shine, y, h, colour_band, seed):
    """One carved totem segment (a friendly dino face block) with a painted brow band."""
    block(wood, (0, y + h / 2, 0), (2.8, h - 0.08, 2.6), bevel=0.3)
    # Snout: a rounded box sticking out of the front.
    block(wood, (0, y + h * 0.36, -1.45), (1.9, h * 0.38, 0.9), bevel=0.25)
    # Painted brow band (proud of the front face by 0.06).
    block(paint, (0, y + h * 0.78, -1.32), (2.5, 0.28, 0.12), bevel=0.04)
    for sx in (-1, 1):
        oriented_ellipsoid(eyes_p, (sx * 0.62, y + h * 0.58, -1.32), (0.26, 0.32, 0.1), normal=(0, 0, -1), rings=4, segments=8)
        oriented_ellipsoid(shine, (sx * 0.62 - 0.08, y + h * 0.64, -1.4), (0.08, 0.08, 0.04), normal=(0, 0, -1), rings=3, segments=6)
    # Smile on the snout front.
    pts = []
    for k in range(7):
        a = math.radians(200 + 140 * k / 6)
        pts.append((0.5 * math.cos(a), y + h * 0.42 + 0.3 * math.sin(a), -1.92))
    tube(eyes_p, pts, 0.06, sides=4)


def build_totem_sign():
    """
    Carved "NUKES!" totem (spec §16): three stacked friendly dino-face segments with painted brow
    bands (teal / lava / sun), topped by a thatch board with "NUKES!" on BOTH faces (R17) and two
    leaf wings. ~14 studs tall.
    """
    m = Model("D2_TotemSign", "ground centre of the totem; faces -Z; board reads from both sides", budget=3000)
    wood = m.piece("Wood", LOG)
    base = m.piece("Base", STONE)
    eyes_p = m.piece("Eyes", INK, material="Smooth")
    shine = m.piece("Shine", (255, 255, 255), material="Smooth")
    teal = m.piece("PaintTeal", TEAL, material="Smooth")
    lava = m.piece("PaintLava", LAVA, material="Smooth")
    sun = m.piece("PaintSun", (255, 204, 60), material="Smooth")
    board = m.piece("Board", THATCH)
    frame = m.piece("Frame", BARK)
    letters = m.piece("Letters", (190, 60, 40), material="Smooth")
    wings = m.piece("Wings", FERN)
    block(base, (0, 0.4, 0), (3.6, 0.8, 3.4), bevel=0.25)
    y = 0.8
    for k, (h, paint) in enumerate(((3.0, teal), (2.8, lava), (2.7, sun))):
        _totem_face(wood, paint, eyes_p, shine, y, h, paint, k)
        y += h
    # Board on top: "NUKES!" both faces.
    bw, bh, bd = 8.4, 2.6, 0.8
    by = y + 0.3 + bh / 2
    block(board, (0, by, 0), (bw, bh, bd), bevel=0.1)
    for sy in (-1, 1):
        cylinder(frame, (-bw / 2 - 0.4, by + sy * bh / 2, 0), (bw / 2 + 0.4, by + sy * bh / 2, 0), 0.3, segments=7)
    cell = min(0.3, (bw - 1.2) / text_cells("NUKES!"))
    sign_text(letters, "NUKES!", (0, by, 0), cell, 0.22, bd / 2)
    # Leaf wings either side of the board.
    for sx in (-1, 1):
        outline = [(sx * (bw / 2 + 0.2), by - 0.6), (sx * (bw / 2 + 2.4), by + 0.4), (sx * (bw / 2 + 3.0), by + 1.6), (sx * (bw / 2 + 1.0), by + 1.0), (sx * (bw / 2 + 0.2), by + 0.6)]
        prism(wings, [(px, py, 0.0) for px, py in outline], (0, 0, 1), 0.14)
    return m


def build_mammoth_fan():
    """
    Baby woolly mammoth sitting up on a mossy stone, big round ears spread forward like a desk
    fan (`Ears` piece: both ears, symmetric about x = 0 so its box centre is on the head's vertical
    axis — the WorldFx row oscillates it about Y). Short rounded tusks, curled trunk, a fur tuft.
    """
    m = Model("D2_MammothFan", "ground centre; faces -Z; Ears box centre on the head axis", budget=2600)
    fur = m.piece("Fur", MAMMOTH)
    fur_light = m.piece("FurLight", MAMMOTH_LIGHT)
    ears = m.piece("Ears", (214, 150, 120), material="Smooth")
    tusks = m.piece("Tusks", BONE, material="Smooth")
    face = m.piece("Face", INK, material="Smooth")
    shine = m.piece("Shine", (255, 255, 255), material="Smooth")
    seat = m.piece("Seat", STONE)
    moss = m.piece("SeatMoss", MOSS)
    block(seat, (0, 0.6, 0.6), (3.6, 1.2, 3.2), bevel=0.35)
    block(moss, (0, 1.3, 0.6), (3.2, 0.24, 2.8), bevel=0.1)
    # Sitting body + legs.
    ellipsoid(fur, (0, 2.9, 0.5), (1.6, 1.7, 1.5), rings=7, segments=12)
    for sx in (-1, 1):
        cylinder(fur, (sx * 0.8, 1.4, -0.9), (sx * 0.85, 1.6, -0.1), 0.55, segments=8)  # front legs out
        ellipsoid(fur_light, (sx * 0.82, 1.4, -1.25), (0.5, 0.4, 0.35), rings=4, segments=8)
        ellipsoid(fur, (sx * 1.2, 1.7, 1.1), (0.7, 0.6, 0.8), rings=4, segments=8)  # haunches
    # Head + fur tuft.
    hc = (0.0, 5.0, -0.3)
    hr = (1.25, 1.15, 1.15)
    ellipsoid(fur, hc, hr, rings=7, segments=12)
    for k in range(3):
        ellipsoid(fur_light, (-0.3 + 0.3 * k, hc[1] + hr[1] - 0.05, hc[2] + 0.1), (0.22, 0.4, 0.22), rings=3, segments=6)
    eyes(face, shine, hc, hr, yaw=28.0, pitch=10.0, size=0.18, tall=1.3)
    # Trunk: a tube curling down and forward, then up at the tip.
    path = [(0.0, 4.6, -1.2), (0.0, 3.9, -1.6), (0.0, 3.3, -1.75), (0.0, 3.0, -2.1), (0.0, 3.25, -2.45)]
    tube(fur_light, path, 0.3, sides=8, radii=[0.42, 0.36, 0.3, 0.26, 0.24])
    # Little rounded tusks curving forward (cream, blunt).
    for sx in (-1, 1):
        tube(tusks, [(sx * 0.45, 4.2, -1.1), (sx * 0.55, 3.7, -1.5), (sx * 0.5, 3.6, -1.95)], 0.12, sides=6, radii=[0.15, 0.13, 0.1])
    smile(face, hc, hr, pitch=-24.0, width=22.0, depth=6.0, thickness=0.05, steps=6)
    # Ears: big round flaps at the head sides, turned 35 degrees toward the front.
    for sx in (-1, 1):
        n = (sx * math.cos(math.radians(35)), 0.0, -math.sin(math.radians(35)))
        c = (sx * 1.75, hc[1] + 0.1, hc[2] - 0.25)
        oriented_ellipsoid(ears, c, (0.95, 1.12, 0.16), normal=n, rings=5, segments=12)
    return m


def build_picnic_logs():
    """Stump table with a leaf plate of berries + two log benches either side (pivot = table)."""
    m = Model("D2_PicnicLogs", "ground centre of the stump table; benches along X at z +-2.6", budget=800)
    logs = m.piece("Logs", BARK)
    ends = m.piece("LogEnds", LOG_END)
    leaf = m.piece("Leaf", FERN)
    berries = m.piece("Berries", BERRY_RED, material="Smooth")
    cylinder(logs, (0, 0.0, 0), (0, 2.3, 0), 1.3, segments=9)
    cylinder(ends, (0, 2.28, 0), (0, 2.36, 0), 1.12, segments=9)
    prism(leaf, [(-0.9, 2.42, 0.0), (0.0, 2.42, -0.6), (0.9, 2.42, 0.0), (0.0, 2.42, 0.7)], (0, 1, 0), 0.08)
    for k in range(5):
        a = 2 * math.pi * k / 5
        ellipsoid(berries, (0.3 * math.cos(a), 2.6, 0.25 * math.sin(a)), (0.18, 0.18, 0.18), rings=3, segments=5)
    for sz in (-1, 1):
        log(logs, (-2.4, 0.62, sz * 2.6), (2.4, 0.62, sz * 2.6), 0.6, segments=8, ends=ends)
    return m


def build_stego_sally():
    """
    Stego Sally (D2 Manager, owner R30): a round lilac stegosaurus with a cream belly, two rows of
    rounded orange back plates, soft tail nubs, a teal market apron with a pocket and a straw sun
    hat with a flower. R30 rig groups; tail + plates + apron ride the Torso, the hat rides the Head.
    """
    from models._npc_rig import rig_split

    m = Model("D2_StegoSally", "ground centre between the feet; faces -Z", budget=3000)
    skin = m.piece("Skin", LILAC, material="Smooth")
    tail = m.piece("Tail", LILAC, material="Smooth")
    belly = m.piece("Belly", (255, 236, 214), material="Smooth")
    face = m.piece("Face", INK, material="Smooth")
    shine = m.piece("Shine", (255, 255, 255), material="Smooth")
    plates = m.piece("Plates", PLATE_ORANGE, material="Smooth")
    apron = m.piece("Apron", TEAL, material="StudsSmall")
    hat = m.piece("Hat", STRAW, material="StudsSmall")
    flower = m.piece("Flower", (255, 120, 180), material="Smooth")
    a = dino_biped(
        {"skin": skin, "belly": belly, "face": face, "shine": shine, "tail": tail},
        body=(1.45, 1.5, 1.35),
        head=(0.95, 0.85, 0.95),
        snout=0.6,
        tail=3.2,
        arm_pose={"left": (14.0, 30.0), "right": (14.0, 30.0)},
    )
    bx, by, bz = a["body_c"]
    bw, bh, bd = a["body"]
    # Back plates: two staggered rows of rounded diamonds along the spine (body + tail start).
    for k in range(6):
        t = k / 5
        ang = math.radians(-20 + 110 * t)  # from the shoulders over the top toward the tail
        y = by + bh * 0.98 * math.cos(ang) * 0.95
        z = bz + bd * 0.98 * math.sin(ang) + 0.3 * t
        size = 0.55 + 0.25 * math.sin(math.pi * t)
        for sx in (-1, 1):
            x = sx * 0.28
            outline = [(0.0, -size * 0.2), (size * 0.55, size * 0.5), (0.0, size * 1.2), (-size * 0.55, size * 0.5)]
            up = (0.0, math.cos(ang), math.sin(ang))
            plate(plates, outline, (x, y + 0.0, z + (0.18 if sx > 0 else -0.18) * 0.5), (1, 0, 0), up=up, thickness=0.14)
    # Soft tail nubs near the tail tip (rounded, never sharp).
    for sx in (-1, 1):
        ellipsoid(plates, (sx * 0.28, by - bh * 0.35 - 1.0, bz + bd * 0.55 + 3.0), (0.14, 0.32, 0.14), rings=3, segments=6)
    # Apron: teal panel over the belly with a pocket and a neck strap.
    hip = a["hip"]
    front = a["belly_front_z"] - 0.12
    prism(apron, [(-0.7, hip + 1.6, front), (0.7, hip + 1.6, front), (0.9, hip + 0.3, front), (-0.9, hip + 0.3, front)], (0, 0, 1), 0.14)
    block(apron, (0.0, hip + 0.75, front - 0.12), (0.8, 0.45, 0.1), bevel=0.04)
    tube(apron, [(-0.6, hip + 1.6, front), (-0.5, hip + 2.4, bz - bd * 0.35), (0.5, hip + 2.4, bz - bd * 0.35), (0.6, hip + 1.6, front)], 0.07, sides=4)
    # Straw sun hat: wide brim + crown + a flower on the band.
    hx, hy, hz = a["head"]
    top = a["head_top"]
    disc(hat, (hx, top - 0.3, hz + 0.05), 1.6, 0.12, segments=14, bevel=0.04)
    revolve(hat, [(0.0, 0.0), (0.82, 0.0), (0.75, 0.55), (0.0, 0.62)], center=(hx, top - 0.2, hz + 0.05), segments=12)
    for k in range(5):
        a2 = 2 * math.pi * k / 5
        ellipsoid(flower, (hx + 0.6 + 0.16 * math.cos(a2), top + 0.05 + 0.16 * math.sin(a2), hz - 0.55), (0.13, 0.13, 0.06), rings=3, segments=6)
    rig_split(m, dino_bones(a), assign={"Tail": "Torso", "Plates": "Torso", "Apron": "Torso", "Hat": "Head", "Flower": "Head"})
    return m


def build_bamboo_fence():
    """16-stud bamboo fence run (pivot = ground centre, runs along X): 5 poles, 2 rails, rope ties."""
    m = Model("D2_BambooFence", "ground centre of the run; runs along X (16 long)", budget=500)
    poles = m.piece("Poles", BAMBOO)
    rings = m.piece("Rings", (150, 160, 70))
    rope = m.piece("Rope", THATCH, material="StudsSmall")
    for k, x in enumerate((-7.6, -3.8, 0.0, 3.8, 7.6)):
        h = 3.2 if k % 2 == 0 else 2.8
        cylinder(poles, (x, 0.0, 0.0), (x, h, 0.0), 0.32, segments=6)
        cylinder(rings, (x, 1.6 - 0.08, 0.0), (x, 1.6 + 0.08, 0.0), 0.37, segments=6)
    for y in (1.0, 2.3):
        cylinder(poles, (-8.0, y, -0.42), (8.0, y, -0.42), 0.2, segments=6)
        for x in (-7.6, 0.0, 7.6):
            cylinder(rope, (x, y - 0.3, -0.4), (x, y + 0.3, -0.4), 0.26, segments=6)
    return m


BUILDERS = {
    "D2_Floor": build_floor,
    "D2_EntryArch": build_arch,
    "D2_Grove": build_grove,
    "D2_Huts": build_huts,
    "D2_ShellCounter": build_shell_counter,
    "D2_LeafAwning": build_leaf_awning,
    "D2_CoconutTill": build_coconut_till,
    "D2_BerryBaskets": build_berry_baskets,
    "D2_TotemSign": build_totem_sign,
    "D2_MammothFan": build_mammoth_fan,
    "D2_PicnicLogs": build_picnic_logs,
    "D2_StegoSally": build_stego_sally,
    "D2_BambooFence": build_bamboo_fence,
}
