"""
event_items.py — Harvest Feast event art (spec §10, 2026-11-01 -> 2026-12-01 UTC).

    GoldenTurkey        the wandering collectible (tap it for Acorns + a Feast Sticker chance). A
                        chubby gold toy turkey, ~3.1 studs tall, with a fanned tail, waddling legs
                        and Neon sparkles. Animation groups (piece-name prefix):
                            Head* (Head, HeadBeak, HeadWattle, HeadFace)  bob / peck about "Head"
                            Tail* (Tail, TailB)                           fan wiggle about "Tail"
                            FeetL / FeetR                                 waddle (alternate) about their hips
                            Glow                                          Neon sparkles (pulse, Body group)
    FeastSticker        one sticker token (pickup / sheet slot): scalloped white sticker disc,
                        orange centre, red maple leaf on BOTH faces, gold Neon rim. Upright, faces
                        -Z, centre at y = 1.6 (spin it about +Y).
    FeastStickerPlaque  the Feast Sticker Sheet board in the event square: wooden board on two posts,
                        gold frame, orange banner (SurfaceGui "FEAST STICKERS" on the Banner front),
                        20 cream sticker sockets (5 x 4), Neon string lights, autumn leaves.
                        Socket centres (board front, z = -0.42): x = -3.8 + 1.9 * c (c = 0..4),
                        y = 6.35 - 1.6 * r (r = 0..3). Place a FeastSticker (scaled 0.55) or a
                        decal in each socket as the player fills the sheet.
    Acorn               event currency pickup, ~1.5 tall: tan nut with a cute face, knobbly cap,
                        curly stem, shine stripe, Neon sparkle star.
    Pie                 pumpkin pie decoration / reward prop, 3.0 wide: steel tin, crimped crust,
                        orange filling, whipped-cream dollops, crust leaf cut-outs.

Coordinates: Roblox space, ORIGIN = ground point under the item, front toward -Z.
Budgets: turkey <= 2,800; sticker <= 1,000; plaque <= 3,000; acorn <= 1,500 (small prop); pie <= 2,000.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import (
    CREAM,
    LEAF,
    Model,
    ORANGE,
    STEEL,
    WOOD,
    WOOD_DARK,
)
from snkit.kit import block, disc
from snkit.shapes import cylinder, ellipsoid, revolve, rot_x

from models._critter_kit import (
    BURNT_ORANGE,
    GOLD,
    GOLD_DARK,
    SNOW,
    SOFT_BLACK,
    SUN_GLOW,
    WATTLE_RED,
    catmull,
    eyes,
    joints_text,
    oriented_ellipsoid,
    plate,
    smile,
    star,
    surface,
    tube,
    tup,
)

MAPLE = [
    (0.0, -0.5), (0.06, -0.2), (0.32, -0.28), (0.26, -0.08), (0.5, 0.06), (0.36, 0.12), (0.42, 0.34),
    (0.2, 0.26), (0.14, 0.5), (0.0, 0.36), (-0.14, 0.5), (-0.2, 0.26), (-0.42, 0.34), (-0.36, 0.12),
    (-0.5, 0.06), (-0.26, -0.08), (-0.32, -0.28), (-0.06, -0.2),
]


def _maple(scale):
    """Cartoon maple-leaf outline scaled to `scale` studs tall-ish (stem at the bottom)."""
    return [(x * scale, y * scale) for x, y in MAPLE]


def build_golden_turkey():
    """Chubby golden toy turkey: fanned two-tone tail, orange beak, red wattle, waddling legs, sparkles."""
    m = Model("GoldenTurkey", "", budget=2800)
    joints = {}
    body = m.piece("Body", GOLD, material="StudsSmall")
    bc, br_ = (0, 1.35, 0.1), (0.82, 0.8, 0.9)
    ellipsoid(body, bc, br_, rings=10, segments=16)
    for side in (-1, 1):  # folded wing bumps
        oriented_ellipsoid(body, (side * 0.78, 1.38, 0.2), (0.5, 0.36, 0.12), normal=(side, 0, 0), up=(0, 0.8, 0.6), rings=5, segments=10)
    head = m.piece("Head", GOLD, material="StudsSmall")
    hc, hr = (0, 2.55, -0.62), (0.34, 0.36, 0.34)
    tube(head, [(0, 1.85, -0.45), (0, 2.2, -0.62), (0, 2.45, -0.62)], 0.2, sides=8)  # neck
    ellipsoid(head, hc, hr, rings=8, segments=14)
    joints["Head"] = (0, 1.9, -0.45)
    beak = m.piece("HeadBeak", ORANGE, material="Smooth")
    p, n = surface(hc, hr, 0, -4)
    cylinder(beak, tup(p - n * 0.05), tup(p + n * 0.22 + Vector((0, -0.04, 0))), 0.09, segments=8, radius_b=0.015)
    wattle = m.piece("HeadWattle", WATTLE_RED, material="Smooth")
    tube(wattle, [tup(p + Vector((0.03, 0.04, -0.06))), tup(p + Vector((0.05, -0.12, -0.12))), tup(p + Vector((0.04, -0.26, -0.1)))], 0.055, sides=6, radii=[0.05, 0.065, 0.06])
    ellipsoid(wattle, tup(p + Vector((0.04, -0.28, -0.1))), (0.07, 0.07, 0.07), rings=4, segments=8)
    face = m.piece("HeadFace", SOFT_BLACK, material="Smooth")
    eyes(face, None, hc, hr, yaw=40, pitch=16, size=0.085, tall=1.2)
    tail_a = m.piece("Tail", GOLD, material="StudsSmall")
    tail_b = m.piece("TailB", BURNT_ORANGE, material="StudsSmall")
    for k in range(9):
        ang = math.radians(-78 + 19.5 * k)
        up = (math.sin(ang), math.cos(ang), 0.0)
        piece = tail_a if k % 2 == 0 else tail_b
        z = 0.82 + (0.03 if k % 2 else 0.0)
        feather = [(-0.2, 0), (0.2, 0), (0.27, 0.85), (0.17, 1.15), (0.0, 1.27), (-0.17, 1.15), (-0.27, 0.85)]
        plate(piece, feather, (math.sin(ang) * 0.4, 1.45 + math.cos(ang) * 0.4, z), (0, 0, 1), up, 0.08)
        # A round "eye spot" near each feather tip (contrast colour).
        tip = Vector((math.sin(ang) * 1.45, 1.45 + math.cos(ang) * 1.45, z - 0.06))
        other = tail_b if piece is tail_a else tail_a
        oriented_ellipsoid(other, tup(tip), (0.13, 0.13, 0.04), normal=(0, 0, -1), rings=3, segments=8)
    joints["Tail"] = (0, 1.45, 0.8)
    for side, name in ((-1, "FeetL"), (1, "FeetR")):
        feet = m.piece(name, ORANGE, material="Smooth")
        hip = (side * 0.36, 0.72, 0.05)
        tube(feet, [hip, (side * 0.38, 0.06, -0.05)], 0.08, sides=6)
        for k in (-1, 0, 1):
            a = math.radians(k * 30)
            tube(feet, [(side * 0.38, 0.05, -0.05), (side * 0.38 + math.sin(a) * 0.3, 0.05, -0.05 - math.cos(a) * 0.3)], 0.055, sides=5)
        joints[name] = hip
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    for x, y, z, s in ((-1.05, 2.4, -0.3, 0.16), (1.1, 2.0, -0.5, 0.13), (0.9, 2.9, 0.4, 0.11), (-0.8, 0.9, -0.8, 0.1)):
        star(glow, (x, y, z), s, 0.05, normal=(0, 0, -1), inner_ratio=0.32)
    m.pivot = (
        "ground point under the turkey (feet at y = 0); faces -Z; Harvest Feast wandering collectible; "
        "FeetL/FeetR alternate (waddle), Head* bobs, Tail* fans; " + joints_text(joints)
    )
    return m


def _scallop(radius, bumps=16, depth=0.08, steps=4):
    """Scalloped (bottle-cap) circle outline for a sticker."""
    pts = []
    total = bumps * steps
    for i in range(total):
        a = 2 * math.pi * i / total
        r = radius * (1 - depth * 0.5 + depth * 0.5 * math.cos(bumps * a))
        pts.append((r * math.cos(a), r * math.sin(a)))
    return pts


def build_feast_sticker():
    """Sticker token: scalloped white disc, orange centre, red maple leaf both faces, gold Neon rim."""
    m = Model("FeastSticker", "", budget=1000)
    c = Vector((0, 1.6, 0))
    border = m.piece("Border", SNOW, material="StudsSmall")
    plate(border, _scallop(1.1), tup(c), (0, 0, -1), (0, 1, 0), 0.2)
    centre = m.piece("Face", BURNT_ORANGE, material="StudsSmall")
    emblem = m.piece("Emblem", WATTLE_RED, material="Smooth")
    for sz in (-1, 1):
        oriented_ellipsoid(centre, tup(c + Vector((0, 0, sz * 0.1))), (0.86, 0.86, 0.05), normal=(0, 0, sz), rings=3, segments=20)
        plate(emblem, _maple(1.1), tup(c + Vector((0, 0.04, sz * 0.17))), (0, 0, sz), (0, 1, 0), 0.05)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    ring = [tup(c + Vector((math.cos(2 * math.pi * i / 28) * 1.12, math.sin(2 * math.pi * i / 28) * 1.12, 0))) for i in range(28)]
    tube(glow, ring, 0.07, sides=5, closed=True)
    m.pivot = "ground point under the sticker; disc centre at y = 1.6, faces -Z (both faces decorated); spin about +Y"
    return m


def build_feast_sticker_plaque():
    """Feast Sticker Sheet board: posts, wooden board, gold frame, banner, 20 sockets, string lights."""
    m = Model("FeastStickerPlaque", "", budget=3000)
    W, H, D = 11.0, 8.0, 0.6
    cy = 5.0
    posts = m.piece("Posts", WOOD_DARK, material="Studs")
    for sx in (-1, 1):
        block(posts, (sx * 4.6, (cy - H / 2 + 0.6) / 2, 0.2), (0.7, cy - H / 2 + 0.6, 0.7), bevel=0.1)
        block(posts, (sx * 4.6, 0.15, 0.2), (1.4, 0.3, 1.4), bevel=0.08)
    board = m.piece("Board", WOOD, material="Studs")
    block(board, (0, cy, 0), (W, H, D), bevel=0.15)
    frame = m.piece("Frame", GOLD, material="StudsSmall")
    t = 0.35
    for y in (cy - H / 2 + t / 2, cy + H / 2 - t / 2):
        block(frame, (0, y, -D / 2 - 0.05), (W + 0.2, t, 0.25), bevel=0.06)
    for x in (-W / 2 + t / 2, W / 2 - t / 2):
        block(frame, (x, cy, -D / 2 - 0.05), (t, H + 0.2, 0.25), bevel=0.06)
    slots = m.piece("Slots", CREAM, material="Smooth")
    for r in range(4):
        for c in range(5):
            x = -3.8 + 1.9 * c
            y = 6.35 - 1.6 * r
            # Thin rounded socket disc standing on the board front (symmetric profile, axis -> Z).
            revolve(slots, [(0.0, -0.06), (0.62, -0.06), (0.68, 0.0), (0.62, 0.06), (0.0, 0.06)], center=(x, y, -D / 2 - 0.02), segments=12, rot=rot_x(90))
    banner = m.piece("Banner", BURNT_ORANGE, material="StudsSmall")
    block(banner, (0, cy + H / 2 + 0.55, -D / 2 - 0.1), (7.0, 1.3, 0.3), bevel=0.1)
    for sx in (-1, 1):  # folded ribbon tails pointing outward (a -Z facing plate maps local +x to -X)
        tail = [(-sx * x, y) for x, y in ((0, -0.6), (1.3, -0.6), (0.95, 0.0), (1.3, 0.6), (0, 0.6))]
        plate(banner, tail, (sx * 3.4, cy + H / 2 + 0.4, -D / 2 - 0.05), (0, 0, -1), (0, 1, 0), 0.2)
    leaves = m.piece("Leaves", WATTLE_RED, material="Smooth")
    leaves_b = m.piece("LeavesGold", GOLD_DARK, material="Smooth")
    for sx in (-1, 1):
        plate(leaves, _maple(1.3), (sx * (W / 2 - 0.3), cy + H / 2 - 0.2, -D / 2 - 0.25), (0, 0, -1), (sx * 0.4, 1, 0), 0.08)
        plate(leaves_b, _maple(1.0), (sx * (W / 2 - 1.0), cy + H / 2 + 0.1, -D / 2 - 0.3), (0, 0, -1), (-sx * 0.3, 1, 0), 0.08)
        plate(leaves, _maple(0.9), (sx * (W / 2 - 0.4), cy - H / 2 + 0.4, -D / 2 - 0.25), (0, 0, -1), (sx * 0.8, 1, 0), 0.08)
    lights = m.piece("Glow", SUN_GLOW, material="Neon")
    wire = m.piece("Wire", LEAF, material="Smooth")
    pts = []
    for i in range(13):
        x = -W / 2 + 0.2 + (W - 0.4) * i / 12
        sag = 0.35 * math.sin(math.pi * ((i % 4) / 4))
        pts.append((x, cy + H / 2 + 0.05 - sag, -D / 2 - 0.35))
    tube(wire, catmull(pts, 2), 0.04, sides=4)
    for p in pts[1:-1]:
        ellipsoid(lights, (p[0], p[1] - 0.2, p[2]), (0.15, 0.2, 0.15), rings=3, segments=6)
    m.pivot = (
        "ground centre between the posts; board faces -Z; Harvest Feast sticker sheet; board centre y = 5; "
        "Banner front takes a SurfaceGui; 20 sockets at x = -3.8 + 1.9c (c 0..4), y = 6.35 - 1.6r (r 0..3), z = -0.42"
    )
    return m


def build_acorn():
    """Acorn pickup: tan nut with a happy face, knobbly dark cap, curly stem, shine, Neon sparkle."""
    m = Model("Acorn", "", budget=1500)
    nut = m.piece("Nut", (232, 172, 98), material="StudsSmall")
    revolve(nut, [(0.0, 0.0), (0.14, 0.05), (0.4, 0.3), (0.55, 0.68), (0.57, 1.0), (0.5, 1.12), (0.0, 1.14)], segments=16)
    cap = m.piece("Cap", WOOD_DARK, material="StudsSmall")
    revolve(cap, [(0.0, 0.98), (0.64, 0.98), (0.68, 1.1), (0.56, 1.28), (0.3, 1.4), (0.0, 1.42)], segments=16)
    for ring_i, (y, r, n) in enumerate(((1.1, 0.66, 10), (1.26, 0.5, 7), (1.37, 0.28, 4))):
        for k in range(n):
            a = 2 * math.pi * (k + 0.5 * (ring_i % 2)) / n
            ellipsoid(cap, (math.cos(a) * r, y, math.sin(a) * r), (0.07, 0.06, 0.07), rings=3, segments=6)
    stem = catmull([(0, 1.38, 0), (0.04, 1.56, 0.02), (0.16, 1.66, 0.0), (0.24, 1.6, -0.02)], 3)
    tube(cap, stem, 0.06, sides=5)
    face = m.piece("Face", SOFT_BLACK, material="Smooth")
    shine = m.piece("Shine", SNOW, material="Smooth")
    fc, fr = (0, 0.66, 0), (0.56, 0.44, 0.56)
    eyes(face, shine, fc, fr, yaw=22, pitch=6, size=0.09, tall=1.25)
    smile(face, fc, fr, pitch=-16, width=12, depth=6, thickness=0.025)
    p, n = surface(fc, fr, 55, 20)
    oriented_ellipsoid(shine, tup(p + n * 0.01), (0.06, 0.16, 0.03), normal=tup(n), up=(0.3, 1, 0), rings=3, segments=8)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    star(glow, (0.55, 1.5, -0.3), 0.16, 0.05, normal=(0, 0, -1), inner_ratio=0.32)
    m.pivot = "ground point under the acorn (nut tip at y = 0); face toward -Z; Harvest Feast currency pickup (bob + spin)"
    return m


def build_pie():
    """Pumpkin pie: steel tin, crimped golden crust, orange filling, cream dollops, leaf cut-outs."""
    m = Model("Pie", "", budget=2000)
    R = 1.5
    tin = m.piece("Tin", STEEL, material="StudsSmall")
    revolve(tin, [(0.0, 0.0), (R * 0.8, 0.0), (R * 0.98, 0.42), (R * 1.06, 0.46), (R * 1.06, 0.52), (R * 0.95, 0.5), (R * 0.8, 0.1), (0.0, 0.1)], segments=24)
    crust = m.piece("Crust", (226, 164, 84), material="StudsSmall")
    revolve(crust, [(R * 0.8, 0.5), (R * 1.02, 0.5), (R * 1.04, 0.66), (R * 0.92, 0.74), (R * 0.8, 0.66)], segments=24, closed=True)
    for k in range(20):  # crimped edge bumps
        a = 2 * math.pi * k / 20
        ellipsoid(crust, (math.cos(a) * R * 0.94, 0.72, math.sin(a) * R * 0.94), (0.16, 0.1, 0.16), rings=3, segments=6)
    for k in range(3):  # crust leaf cut-outs resting on the filling
        a = 2 * math.pi * k / 3 + 0.4
        plate(crust, _maple(0.5), (math.cos(a) * 0.62, 0.66, math.sin(a) * 0.62), (0, 1, 0), (math.cos(a), 0, math.sin(a)), 0.05)
    filling = m.piece("Filling", (236, 122, 40), material="StudsSmall")
    disc(filling, (0, 0.1, 0), R * 0.86, 0.52, segments=24, bevel=0.04)
    cream = m.piece("Cream", SNOW, material="Smooth")
    for k, (x, z, s) in enumerate(((0.0, 0.0, 1.0), (0.0, -0.95, 0.55), (0.85, 0.48, 0.55), (-0.85, 0.48, 0.55))):
        revolve(cream, [(0.0, 0.62), (0.36 * s, 0.62), (0.32 * s, 0.76), (0.22 * s, 0.86), (0.12 * s, 0.98), (0.0, 1.05 * (0.8 + 0.2 * s))], center=(x, 0, z), segments=10)
    m.pivot = "ground centre under the pie tin; Harvest Feast decoration / reward prop; 3.0 wide x 1.05 tall"
    return m


BUILDERS = {
    "GoldenTurkey": build_golden_turkey,
    "FeastSticker": build_feast_sticker,
    "FeastStickerPlaque": build_feast_sticker_plaque,
    "Acorn": build_acorn,
    "Pie": build_pie,
}
