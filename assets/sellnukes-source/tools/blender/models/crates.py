"""
crates.py — Supply Crate / Mega Crate / Golden Crate (spec §8: bought with Gems or Robux; the reveal
animation pops the lid and items fly out).

Each crate is a body + a SEPARATE lid so the reveal can open it:

    Box / Trim / Badge / Glow / Gems ...   body pieces (stay put; shake as one)
    Lid*  (Lid, LidTrim, LidGem, ...)      group "Lid": rotate about the hinge line (axis +X) at the
                                           back top edge — a POSITIVE angle about +X raises the front
                                           edge (open ~110 deg), then let it bounce.

Coordinates: Roblox space, ORIGIN = ground centre under the crate; the badge face looks toward -Z.
Pivot strings carry the hinge: `joints Lid@(0,y,z)`.

    SupplyCrate   body 3.2 x 2.1 x 2.6 (2.66 tall with the lid)
                  wooden slat crate, dark-steel corner brackets + rivets, hazard-striped kick band,
                  yellow badge with a Neon trefoil, rope-grip lid handle
    MegaCrate     body 3.8 x 2.5 x 3.0 (3.86 tall with the lid gem)
                  purple armoured crate, gold trim + corner caps, Neon cyan seam strips, gold star
                  badge, big pink gem on the lid
    GoldenCrate   body 3.6 x 2.4 x 2.8 (3.58 tall with the crown)
                  all-gold treasure crate, snow-white trim, pink gem studs, Neon sparkle stars,
                  rounded crown points on the lid rims, glowing blue lid gem

Budgets: <= 2,500 triangles (shop + reveal show one or two at a time).
"""

from __future__ import annotations

from snkit.core import (
    DARK_STEEL,
    GLOW_GREEN,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    Model,
    PURPLE,
    WOOD,
    WOOD_DARK,
)
from snkit.kit import block, hazard_band, trefoil
from snkit.shapes import ellipsoid, revolve

from models._critter_kit import (
    GOLD,
    GOLD_DARK,
    HOT_PINK,
    SKY_GLOW,
    SNOW,
    SUN_GLOW,
    plate,
    star,
    tube,
)

BUDGET = 2500


def _crate_model(key: str, width: float, body_h: float, depth: float, lid_h: float, note: str) -> Model:
    """Model with the hinge written into the pivot string (back top edge of the body)."""
    pivot = (
        f"ground centre under the crate; badge faces -Z; {note}; body top y = {body_h:g}; "
        f"lid height {lid_h:g}; joints Lid@(0,{body_h:g},{depth / 2:g})"
    )
    m = Model(key, pivot, budget=BUDGET)
    return m


def _slats(piece, width, height, depth, slat=0.42, proud=0.06, gap=0.08):
    """Horizontal wooden slats proud of every side face (planked crate look)."""
    y = 0.35 + slat / 2
    while y + slat / 2 <= height - 0.25:
        block(piece, (0, y, -depth / 2 - proud / 2), (width - 0.6, slat - gap, proud + 0.02), bevel=0.03)
        block(piece, (0, y, depth / 2 + proud / 2), (width - 0.6, slat - gap, proud + 0.02), bevel=0.03)
        block(piece, (-width / 2 - proud / 2, y, 0), (proud + 0.02, slat - gap, depth - 0.6), bevel=0.03)
        block(piece, (width / 2 + proud / 2, y, 0), (proud + 0.02, slat - gap, depth - 0.6), bevel=0.03)
        y += slat


def _corners(piece, width, height, depth, post=0.34, y0=0.0):
    """Vertical L-bracket corner posts + top and bottom rim bands."""
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(piece, (sx * (width / 2 - post / 2 + 0.06), y0 + height / 2, sz * (depth / 2 - post / 2 + 0.06)), (post, height, post), bevel=0.06)
    for y in (y0 + 0.15, y0 + height - 0.12):
        h = 0.3 if y < y0 + 1 else 0.24
        block(piece, (0, y, -depth / 2 - 0.04), (width + 0.04, h, 0.14), bevel=0.04)
        block(piece, (0, y, depth / 2 + 0.04), (width + 0.04, h, 0.14), bevel=0.04)
        block(piece, (-width / 2 - 0.04, y, 0), (0.14, h, depth + 0.04), bevel=0.04)
        block(piece, (width / 2 + 0.04, y, 0), (0.14, h, depth + 0.04), bevel=0.04)


def _rivets(piece, width, height, depth, y0=0.0, r=0.07):
    """Little round rivet heads on the corner posts (front + back faces)."""
    for sx in (-1, 1):
        for sz in (-1, 1):
            for y in (y0 + 0.45, y0 + height - 0.45):
                z = sz * (depth / 2 + 0.12)
                ellipsoid(piece, (sx * (width / 2 - 0.1), y, z), (r, r, r * 0.6), rings=3, segments=6)


def _lid(lid, trim, width, depth, body_h, lid_h, overhang=0.12):
    """Chamfered lid slab + rim band (trim), sitting on the body top."""
    block(lid, (0, body_h + lid_h / 2, 0), (width + overhang * 2, lid_h, depth + overhang * 2), bevel=0.12)
    block(trim, (0, body_h + 0.08, 0), (width + overhang * 2 + 0.08, 0.16, depth + overhang * 2 + 0.08), bevel=0.04)


def build_supply_crate():
    """Wooden supply crate: slats, steel brackets, hazard kick band, yellow badge + Neon trefoil."""
    w, h, d, lid_h = 3.2, 2.1, 2.6, 0.5
    m = _crate_model("SupplyCrate", w, h, d, lid_h, "Supply Crate (gems / Robux)")
    box = m.piece("Box", WOOD, material="Studs")
    block(box, (0, h / 2, 0), (w, h, d), bevel=0.1)
    slats = m.piece("Slats", WOOD_DARK, material="Studs")
    _slats(slats, w, h, d)
    trim = m.piece("Trim", DARK_STEEL, material="StudsSmall")
    _corners(trim, w, h, d)
    _rivets(trim, w, h, d)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW, material="StudsSmall")
    black = m.piece("HazardBlack", HAZARD_BLACK, material="StudsSmall")
    hazard_band(yellow, black, (0, 0.18, -d / 2 - 0.14), (w - 0.8, 0.26, 0.08), stripe=0.36, angle=55)
    # Badge: yellow disc on the front with a glowing trefoil.
    revolve(yellow, [(0.0, -0.06), (0.62, -0.06), (0.68, 0.0), (0.62, 0.06), (0.0, 0.06)], center=(0, 1.15, -d / 2 - 0.14), segments=20, rot=_face(-1))
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    trefoil(glow, (0, 1.15, -d / 2 - 0.22), 0.52, 0.06, normal=(0, 0, -1))
    lid = m.piece("Lid", WOOD, material="Studs")
    lid_trim = m.piece("LidTrim", DARK_STEEL, material="StudsSmall")
    _lid(lid, lid_trim, w, d, h, lid_h)
    for sx in (-1, 1):  # lid slat grooves (dark planks on top)
        block(lid_trim, (sx * 0.75, h + lid_h + 0.03, 0), (0.12, 0.06, d + 0.1), bevel=0.02)
    # Rope-grip handle on the lid front.
    tube(lid_trim, [(-0.5, h + lid_h * 0.5, -d / 2 - 0.18), (-0.35, h + lid_h * 0.5, -d / 2 - 0.42), (0.35, h + lid_h * 0.5, -d / 2 - 0.42), (0.5, h + lid_h * 0.5, -d / 2 - 0.18)], 0.07, sides=6)
    return m


def build_mega_crate():
    """Purple armoured crate: gold trim + corner caps, Neon cyan seams, gold star badge, lid gem."""
    w, h, d, lid_h = 3.8, 2.5, 3.0, 0.6
    m = _crate_model("MegaCrate", w, h, d, lid_h, "Mega Crate (gems / Robux)")
    box = m.piece("Box", PURPLE, material="Studs")
    block(box, (0, h / 2, 0), (w, h, d), bevel=0.14)
    trim = m.piece("Trim", GOLD, material="StudsSmall")
    _corners(trim, w, h, d, post=0.42)
    for sx in (-1, 1):  # chunky corner caps at the bottom
        for sz in (-1, 1):
            block(trim, (sx * (w / 2 - 0.1), 0.2, sz * (d / 2 - 0.1)), (0.6, 0.4, 0.6), bevel=0.1)
    glow = m.piece("Glow", SKY_GLOW, material="Neon")
    for sz in (-1, 1):  # seam strips across front + back
        block(glow, (0, h * 0.62, sz * (d / 2 + 0.04)), (w - 1.0, 0.12, 0.08), bevel=0.03)
        block(glow, (0, h * 0.3, sz * (d / 2 + 0.04)), (w - 1.0, 0.12, 0.08), bevel=0.03)
    for sx in (-1, 1):
        block(glow, (sx * (w / 2 + 0.04), h * 0.46, 0), (0.08, 0.12, d - 1.0), bevel=0.03)
    badge = m.piece("Badge", GOLD_DARK, material="StudsSmall")
    revolve(badge, [(0.0, -0.07), (0.66, -0.07), (0.72, 0.0), (0.66, 0.07), (0.0, 0.07)], center=(0, h * 0.46, -d / 2 - 0.1), segments=20, rot=_face(-1))
    star(trim, (0, h * 0.46, -d / 2 - 0.2), 0.52, 0.1, normal=(0, 0, -1))
    lid = m.piece("Lid", PURPLE, material="Studs")
    lid_trim = m.piece("LidTrim", GOLD, material="StudsSmall")
    _lid(lid, lid_trim, w, d, h, lid_h, overhang=0.15)
    block(lid_trim, (0, h + lid_h + 0.08, 0), (w * 0.55, 0.16, d * 0.55), bevel=0.06)
    gem = m.piece("LidGem", HOT_PINK, material="Smooth")
    revolve(gem, [(0.0, 0.0), (0.42, 0.12), (0.5, 0.3), (0.3, 0.55), (0.0, 0.62)], center=(0, h + lid_h + 0.14, 0), segments=8)
    return m


def build_golden_crate():
    """All-gold treasure crate: white trim, pink gem studs, Neon sparkles, crown lid + blue gem."""
    w, h, d, lid_h = 3.6, 2.4, 2.8, 0.6
    m = _crate_model("GoldenCrate", w, h, d, lid_h, "Golden Crate (Robux)")
    box = m.piece("Box", GOLD, material="Studs")
    block(box, (0, h / 2, 0), (w, h, d), bevel=0.14)
    trim = m.piece("Trim", SNOW, material="StudsSmall")
    _corners(trim, w, h, d, post=0.38)
    gems = m.piece("Gems", HOT_PINK, material="Smooth")
    for sz in (-1, 1):
        for sx in (-0.9, 0.0, 0.9):
            if sz < 0 and sx == 0.0:
                continue  # front centre holds the badge
            revolve(gems, [(0.0, -0.06), (0.17, -0.02), (0.2, 0.05), (0.0, 0.14)], center=(sx, h * 0.5, sz * (d / 2 + 0.04)), segments=6, rot=_face(sz))
    badge = m.piece("Badge", GOLD_DARK, material="StudsSmall")
    revolve(badge, [(0.0, -0.07), (0.64, -0.07), (0.7, 0.0), (0.64, 0.07), (0.0, 0.07)], center=(0, h * 0.5, -d / 2 - 0.1), segments=20, rot=_face(-1))
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    star(glow, (0, h * 0.5, -d / 2 - 0.2), 0.5, 0.08, normal=(0, 0, -1))
    for sx, y in ((-1.3, h * 0.82), (1.25, h * 0.22), (1.35, h * 0.8)):
        star(glow, (sx, y, -d / 2 - 0.12), 0.16, 0.05, normal=(0, 0, -1), inner_ratio=0.3)
    lid = m.piece("Lid", GOLD, material="Studs")
    lid_trim = m.piece("LidTrim", SNOW, material="StudsSmall")
    _lid(lid, lid_trim, w, d, h, lid_h, overhang=0.14)
    top = h + lid_h
    points = m.piece("LidCrown", GOLD_DARK, material="StudsSmall")
    for k in range(5):  # rounded crown points along the lid front + back rims, a bead on each tip
        x = -1.4 + 0.7 * k
        for sz in (-1, 1):
            plate(points, [(-0.22, 0), (0.22, 0), (0.08, 0.3), (0.0, 0.34), (-0.08, 0.3)], (x, top - 0.08, sz * (d / 2 - 0.02)), (0, 0, sz), (0, 1, 0), 0.1)
            ellipsoid(points, (x, top + 0.3, sz * (d / 2 - 0.02)), (0.07, 0.07, 0.07), rings=3, segments=6)
    gem = m.piece("LidGem", SKY_GLOW, material="Neon")
    revolve(gem, [(0.0, 0.0), (0.38, 0.1), (0.46, 0.28), (0.28, 0.5), (0.0, 0.58)], center=(0, top, 0), segments=8)
    return m


def _face(sz):
    """Rotation turning a Y-axis revolve into a disc facing -Z (sz = -1) or +Z (sz = +1)."""
    from snkit.shapes import rot_x

    return rot_x(90 if sz < 0 else -90)


BUILDERS = {
    "SupplyCrate": build_supply_crate,
    "MegaCrate": build_mega_crate,
    "GoldenCrate": build_golden_crate,
}

