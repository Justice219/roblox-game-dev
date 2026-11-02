"""
shop_props.py — small candy-toy props for the Shop's rotating ViewportFrames (owner R39: "in the shop
we should use real 3d models"). Each prop stands in for a shop product that has no game model of its
own (pets / eggs / crates / nukes already come from MeshAssets).

    Shop_CashStack    three fanned bundles of green banknotes, each with a cream paper band carrying a
                      green "$" (front and back); ink frame + seals on the top note; two gold coins.
    Shop_GemCluster   five faceted purple crystals (Crystal* pieces -> WorldFx soft glow, never move)
                      on a lumpy light-lilac rock base with pebbles; white glint + tiny Neon sparkle.
    Shop_SpinToken    thick gold coin standing on its edge whose faces are an 8-wedge rainbow prize
                      wheel (wedges run through the coin, so BOTH faces match), white hub, dividers and
                      pegs, red pointer on the top rim.
    Shop_BoostPotion  round-bottom glass flask (Glass, 65 % transparent) with glowing green `Liquid`
                      (small Neon, PointLight via WorldFx), cork, fizz bubbles and a yellow starburst
                      badge curved onto the bulb front carrying a bold red "2x".
    Shop_MoneyBag     plump tan sack with a frilled gathered top, brown rope tie + bow at the neck, a big
                      green "$" wrapped onto the front, a stitched patch on the back, two gold coins.
    Shop_VipCrown     flared five-point gold crown (one point faces -Z), light-gold base band set with
                      red / blue / green jewels, pearl tips, purple velvet cushion and a gold orb.
    Shop_ServerBoost  blue coin standing on its edge with a chubby cartoon rocket bursting through it
                      diagonally (nose out of the top-right rim, flame out of the bottom-left as seen
                      from the front), red fins / nose, portholes on both faces, yellow lightning bolts.
    Shop_CashPile     cash packs: seven banded bundles stacked as a pyramid (2 x 2 base, crosswise
                      middle pair, top bundle), "$" bands on every side, coin stack + loose coins.
    Shop_GemChest     gem packs: open wooden chest (gold rim bands, straps, lock + keyhole, lid hinged
                      open at the back) heaped with brilliant-cut purple gems, two spilled in front.
    Shop_Teleporter   round pad: hazard-striped slate base, teal top with a blue swirl and a Neon ring,
                      three glowing emitter posts, soft transparent Neon light column, yellow hoops.
    Shop_FastShoe     chunky blue sneaker (lofted upper, white sole / toe cap / laces / tongue, navy
                      tread + stripe), yellow bolt on both sides, white heel wings; toe points -X.
    Shop_AutoClicker  yellow cartoon hand pointing up (fist knuckles, thumb, blue cuff) with yellow
                      click dashes at the fingertip, beside a black-rimmed white cursor arrow.
    Shop_OfflineMoon  puffy crescent (lofted, swells mid-arc) with a sleeping face, blush and craters
                      front + back, and a deep-purple "Zzz" drifting out of its opening.
    Shop_PetSlots     pink-rimmed cream pet tag on its edge with a brown paw print on both faces and a
                      green "+" (white border) at the upper right.
    Shop_TripleEgg    three candy eggs (pink / mint / blue, yellow spots) in a sunny straw nest.

Contract (same as every SellNukes model): Roblox space (studs, +Y up), PIVOT = ground centre under
the prop (lowest point at y = 0), FRONT faces -Z (+X is the prop's right-hand side, i.e. the viewer's
LEFT when looking at the front). Props are ~1.6-3.4 studs tall; the shop camera frames each from
MeshLibrary.getBounds; every prop reads from any yaw (decorated front AND back) because the shop
spins them.

Asymmetric props call `_recentre` (bounding box centred on the pivot, lowest point y = 0) or
`_ground` (lowest point y = 0 only) last, so the shop turntable spins them about their middle.

Budgets: <= 2,000 triangles per prop (shop viewports draw a handful at once), <= 12 pieces.
Piece names avoid WorldFx words (Rocket, Glow, Core, Wheel, Fan, ...) except where the effect is
intended: `Crystal*` (soft pulsing light) and `Liquid` (potion light), see WorldFxConfig.

Text / symbols are geometry (never textures): `_dollar`, `_two`, `_letter_x` return 2-D outlines that
`_glyph` extrudes with `plate`; a -Z facing plate maps local +x to the viewer's right, so outlines are
authored exactly as they should read from the front (and a +Z plate reads correctly from the back).

Example (build + look):
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only Shop_CashStack
    python3 tools/blender/contact_sheet.py --only Shop_CashStack
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import (
    CREAM,
    DEEP_BLUE,
    GLASS,
    GLOW_LIGHT,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LIME,
    Model,
    ORANGE,
    PINK,
    PURPLE,
    SKY_BLUE,
    TOY_RED,
    WHITE,
    WOOD,
    WOOD_DARK,
    YELLOW,
    br,
    rb,
)
from snkit.kit import block, hazard_ring
from snkit.shapes import add_faces, cylinder, ellipsoid, extrude_outline, loft, prism, revolve, ring_tube, rot_x, rot_y, rot_z

from models._critter_kit import (
    BLUSH,
    SKY_GLOW,
    SNOW,
    SOFT_BLACK,
    model_bounds,
    oriented_ellipsoid,
    plate,
    star,
    transform_model,
    tube,
)

# ------------------------------------------------------------------------------------------------
# Shop-only colours (candy palette; the stud map darkens these ~10 % in game).
# Colour pass (lead, after owner R47 "very light colored" / washed out): props must read CANDY-VIVID
# in a small viewport, so every main colour keeps one channel at 255 and its lowest channel low
# (high saturation survives both the stud darkening and any viewport haze). Gold is one saturated
# toy gold with LIGHTER (never darker / brown) accents for bands, locks and shine lines.
# ------------------------------------------------------------------------------------------------
TOY_GOLD = (255, 196, 40)  # every gold surface: coins, rims, crown, chest trim
GOLD_LIGHT = (255, 228, 104)  # lighter gold accents (crown band, lock, rim shine lines, star caps)
NOTE_GREEN = (126, 214, 112)  # banknote faces
NOTE_DARK = (82, 170, 84)  # alternate note layers (edge stripes read as "a stack of bills")
INK_GREEN = (40, 132, 66)  # "$" ink, note frame, bag "$"
ROCK = (198, 182, 240)  # light lilac stone (matches the crystals; the old grey read muddy)
GEM_PURPLE = (168, 98, 252)
GEM_DEEP = (118, 62, 206)
GEM_PALE = (200, 150, 255)
WEDGE_TEAL = (52, 200, 176)
CORK = WOOD
BAG_TAN = (255, 178, 74)  # warm, bright toy tan
BAG_PATCH = (255, 226, 150)
ROPE_BROWN = (190, 104, 44)
VELVET = PURPLE
JEWEL_RED = (236, 40, 64)
JEWEL_BLUE = (40, 120, 255)
JEWEL_GREEN = (40, 200, 96)
COIN_RIM_BLUE = DEEP_BLUE
COIN_FACE_BLUE = SKY_BLUE
PORTHOLE = (36, 70, 160)


# ------------------------------------------------------------------------------------------------
# 2-D outline helpers (glyphs, wedges, flames). All outlines are [(x, y)] in plate-local space.
# ------------------------------------------------------------------------------------------------


def _arc(cx: float, cy: float, rx: float, ry: float, a0: float, a1: float, steps: int) -> list:
    """
    Points along an elliptical arc from angle a0 to a1 (degrees, CCW positive; a1 < a0 walks CW).

    Example: _arc(0, 0, 1, 1, 0, 90, 2) -> [(1, 0), (0.707, 0.707), (0, 1)]
    """
    out = []
    for i in range(steps + 1):
        a = math.radians(a0 + (a1 - a0) * i / steps)
        out.append((cx + rx * math.cos(a), cy + ry * math.sin(a)))
    return out


def _ribbon(path: list, width: float) -> list:
    """
    Closed outline of a constant-width stroke along a 2-D centre line (left side, then right side
    reversed). Normals are averaged at each point, so smooth curves keep their width; keep the
    curve radius > width / 2 or the outline folds over itself.

    Example: _ribbon([(0, 0), (1, 0)], 0.2) -> [(0, 0.1), (1, 0.1), (1, -0.1), (0, -0.1)]
    """
    half = width / 2
    left, right = [], []
    count = len(path)
    for i, (x, y) in enumerate(path):
        ax, ay = path[max(i - 1, 0)]
        bx, by = path[min(i + 1, count - 1)]
        tx, ty = bx - ax, by - ay
        length = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / length, tx / length
        left.append((x + nx * half, y + ny * half))
        right.append((x - nx * half, y - ny * half))
    return left + right[::-1]


def _segment(a: tuple, b: tuple, width: float) -> list:
    """Rectangle outline of a straight stroke from a to b (a 2-point ribbon)."""
    return _ribbon([a, b], width)


def _rect(x0: float, y0: float, x1: float, y1: float) -> list:
    """Axis-aligned rectangle outline, counter-clockwise."""
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def _shift(outline: list, dx: float, dy: float) -> list:
    """Translate a 2-D outline (lays several glyphs out on one plate origin)."""
    return [(x + dx, y + dy) for x, y in outline]


def _dollar(h: float, steps: int = 8) -> list:
    """
    A chunky "$" of height h centred on (0, 0) as [(outline, extra_depth)]. The S is one ribbon
    (top bowl CCW 25 deg -> 270 deg, bottom bowl CW 90 deg -> -155 deg: point-symmetric); the
    vertical bar is extruded slightly deeper (+extra) so it sits ON the S (no z-fighting faces).
    `steps` = points per bowl arc: 8 for hero glyphs (~144 tris), 5 for small repeated ones (~96 tris).
    """
    rx, ry = h * 0.27, h * 0.25
    top = _arc(0.0, h * 0.25, rx, ry, 25, 270, steps)
    bottom = _arc(0.0, -h * 0.25, rx, ry, 90, -155, steps)
    s_curve = _ribbon(top + bottom[1:], h * 0.17)
    bar = _rect(-h * 0.06, -h * 0.66, h * 0.06, h * 0.66)
    return [(s_curve, 0.0), (bar, 0.04)]


def _two(h: float) -> list:
    """A bold "2" of height h centred on (0, 0): top bowl + diagonal (ribbon) and a base bar."""
    bowl = _arc(0.0, h * 0.22, h * 0.27, h * 0.27, 160, -38, 8)
    stroke = _ribbon(bowl + [(-h * 0.24, -h * 0.4)], h * 0.19)
    base = _rect(-h * 0.33, -h * 0.5, h * 0.31, -h * 0.31)
    return [(stroke, 0.0), (base, 0.03)]


def _letter_x(h: float) -> list:
    """A lowercase "x" (x-height 0.62 h) sitting on the "2"'s baseline; one bar deeper than the other."""
    w = h * 0.17
    lo, hi = -h * 0.5, h * 0.1
    return [
        (_segment((-h * 0.22, lo + w * 0.35), (h * 0.22, hi - w * 0.35), w), 0.0),
        (_segment((h * 0.22, lo + w * 0.35), (-h * 0.22, hi - w * 0.35), w), 0.03),
    ]


def _glyph(piece, parts: list, origin, normal, depth: float, up=(0, 1, 0), dx: float = 0.0, dy: float = 0.0):
    """
    Extrude glyph parts [(outline, extra_depth)] as plates at `origin` facing `normal`.
    dx / dy shift the glyph in plate space (dx > 0 = viewer's right for that face).
    """
    for outline, extra in parts:
        plate(piece, _shift(outline, dx, dy), origin, normal, up, depth + extra)


def _starburst(r_out: float, r_in: float, points: int) -> list:
    """Star-shaped badge outline (alternating outer / inner radii), first point straight up."""
    out = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = math.pi / 2 + math.pi * i / points
        out.append((r * math.cos(a), r * math.sin(a)))
    return out


# ------------------------------------------------------------------------------------------------
# 3-D helpers
# ------------------------------------------------------------------------------------------------


def _verts_from(piece, start: int) -> list:
    """BMesh vertices added to `piece` since it had `start` vertices (for post-deforming a detail)."""
    piece.bm.verts.ensure_lookup_table()
    return [piece.bm.verts[i] for i in range(start, len(piece.bm.verts))]


def _wrap_z(piece, start: int, surface_z, reference_z: float):
    """
    Wrap geometry added since `start` onto a curved body: every vertex moves along Z by
    surface_z(x, y) - reference_z, so a flat glyph authored against `reference_z` follows the
    body's curvature (a "$" printed on a round bag instead of a flat sign floating in front of it).
    """
    for vert in _verts_from(piece, start):
        x, y, z = br(vert.co)
        vert.co = rb((x, y, z + surface_z(x, y) - reference_z))


def _profile_radius(profile: list, y: float) -> float:
    """Radius of a revolve profile [(r, y)] at height y (linear interpolation; 0 outside)."""
    for (r0, y0), (r1, y1) in zip(profile, profile[1:]):
        if min(y0, y1) <= y <= max(y0, y1) and abs(y1 - y0) > 1e-9:
            t = (y - y0) / (y1 - y0)
            return r0 + (r1 - r0) * t
    return 0.0


def _sphere_patch(piece, outline: list, center, radius: float, t0: float, t1: float, side: float = -1.0):
    """
    Curved badge: a STAR-SHAPED 2-D outline (relative to its own centre at plate-space (0, 0))
    projected onto a sphere (centre, radius) on the -Z (side=-1) or +Z (side=+1) face, as a shell
    from radius + t0 to radius + t1. Fan-triangulated from the centre, so any star-shaped outline
    (discs, starbursts) works. `outline` coordinates are viewer-space: +x = viewer's right.
    """
    c = Vector(center)
    flip = -1.0 if side < 0 else 1.0  # viewer's right is -X on the front face, +X on the back face

    def project(x: float, y: float, t: float) -> tuple:
        d = Vector((flip * x, y, side * math.sqrt(max(radius * radius - x * x - y * y, 1e-4))))
        p = c + d.normalized() * (radius + t)
        return (p.x, p.y, p.z)

    count = len(outline)
    verts = [project(0.0, 0.0, t1)] + [project(x, y, t1) for x, y in outline]
    verts += [project(0.0, 0.0, t0)] + [project(x, y, t0) for x, y in outline]
    inner0 = count + 1
    faces = []
    for i in range(count):
        j = (i + 1) % count
        faces.append((0, 1 + i, 1 + j))  # outer fan
        faces.append((inner0, inner0 + 1 + j, inner0 + 1 + i))  # inner fan (reversed)
        faces.append((1 + i, inner0 + 1 + i, inner0 + 1 + j, 1 + j))  # side wall
    add_faces(piece, verts, faces)


def _coin(piece, center, radius: float, height: float, segments: int = 16, axis: str = "Y", rot=None):
    """
    Small chunky coin (bevelled disc) centred on `center`. axis="Y" lies flat; pass `rot` to lean it.
    """
    b = min(0.05, height * 0.3)
    profile = [
        (0.0, -height / 2),
        (radius - b, -height / 2),
        (radius, -height / 2 + b),
        (radius, height / 2 - b),
        (radius - b, height / 2),
        (0.0, height / 2),
    ]
    revolve(piece, profile, center=center, segments=segments, rot=rot)


# ================================================================================================
# 1. Shop_CashStack
# ================================================================================================


def build_cash_stack():
    """Three fanned banknote bundles (striped layers), cream bands with "$" both sides, gold coins."""
    m = Model(
        "Shop_CashStack",
        "ground centre under the cash stack (bottom note at y = 0); front faces -Z; shop viewport prop; "
        "3.4 wide x 2.1 tall; banknote bundles with a '$' band front and back",
        budget=2000,
    )
    notes = m.piece("Notes", NOTE_GREEN, material="StudsSmall")
    notes_dark = m.piece("NotesDark", NOTE_DARK, material="StudsSmall")
    band = m.piece("Band", CREAM, material="StudsSmall")
    ink = m.piece("Ink", INK_GREEN, material="Smooth")
    coins = m.piece("Coins", TOY_GOLD, material="StudsSmall")

    length, depth = 3.0, 1.45  # one banknote (x by z)
    layer = 0.17  # thickness of one note layer
    layers = 4  # layers per bundle -> bundle height 0.68
    # (yaw deg, x offset, z offset) per bundle, bottom -> top: the stack fans out as it rises.
    bundles = [(-7.0, 0.05, 0.05), (4.0, -0.08, -0.04), (13.0, 0.06, 0.02)]
    jitter = [(-1.2, 0.03, 0.0), (0.9, -0.02, 0.02), (-0.5, 0.02, -0.02), (1.4, -0.03, 0.01)]
    y = 0.0
    top_rot = None
    top_y = 0.0
    top_c = (0.0, 0.0)
    for b_index, (yaw, bx, bz) in enumerate(bundles):
        bundle_y0 = y
        for k in range(layers):
            jy, jx, jz = jitter[(k + b_index) % len(jitter)]
            rot = rot_y(yaw + jy)
            piece = notes if (k + b_index) % 2 == 1 else notes_dark
            if k == layers - 1:
                piece = notes  # the top note of every bundle shows the light face
            block(piece, (bx + jx, y + layer / 2, bz + jz), (length, layer, depth), bevel=0.05, rot=rot)
            y += layer
        # Paper band around the middle of the bundle (+0.04 all round so it wraps the notes).
        rot = rot_y(yaw)
        h = y - bundle_y0
        bc = Vector((bx, bundle_y0 + h / 2, bz))
        # Band: flush with the bundle's base (never below the ground), 0.025 proud on top.
        block(band, (bc.x, bundle_y0 + (h + 0.025) / 2, bc.z), (0.78, h + 0.025, depth + 0.1), bevel=0.04, rot=rot)
        # "$" printed on the band, front (-Z) and back (+Z) faces, following the bundle's yaw.
        for side in (-1, 1):
            n = rot @ Vector((0, 0, side))
            origin = bc + n * ((depth + 0.1) / 2 + 0.02)
            # 0.74 h keeps the "$" bar (+-0.66 glyph h) inside the band, so nothing dips below y = 0.
            _glyph(ink, _dollar(h * 0.74), tuple(origin), tuple(n), 0.06)
        top_rot, top_y, top_c = rot, y, (bx, bz)
    # Ink on the top note: a thin frame and two round seals either side of the band.
    tx, tz = top_c
    for x0, x1, z0, z1 in (
        (-1.32, 1.32, -0.58, -0.52),
        (-1.32, 1.32, 0.52, 0.58),
        (-1.32, -1.26, -0.58, 0.58),
        (1.26, 1.32, -0.58, 0.58),
    ):
        c = top_rot @ Vector(((x0 + x1) / 2, 0, (z0 + z1) / 2))
        block(ink, (tx + c.x, top_y + 0.012, tz + c.z), (x1 - x0, 0.03, z1 - z0), bevel=0.0, rot=top_rot)
    for sx in (-1, 1):
        c = top_rot @ Vector((sx * 0.86, 0, 0))
        oriented_ellipsoid(ink, (tx + c.x, top_y + 0.005, tz + c.z), (0.3, 0.3, 0.03), normal=(0, 1, 0), up=(0, 0, 1), rings=3, segments=14)
    # Two gold coins: one flat in front-left, one leaning on the bottom bundle's front-right corner.
    _coin(coins, (1.25, 0.06, -1.15), 0.38, 0.12)
    _coin(coins, (-1.05, 0.42, -1.0), 0.38, 0.12, rot=rot_y(-20) @ rot_x(-70))
    return m


# ================================================================================================
# 2. Shop_GemCluster
# ================================================================================================


def _crystal(piece, base, direction, radius: float, height: float, spin: float = 0.0):
    """
    One faceted hexagonal crystal rooted at `base` (0.3 studs buried in the rock) growing along
    `direction`: bevelled foot, straight shaft, two-step pointed tip (more facets = more "gem").
    """
    d = Vector(direction).normalized()
    tilt = Vector((0, 1, 0)).rotation_difference(d).to_matrix()
    rot = tilt @ rot_y(spin)
    tip = radius * 1.5
    profile = [
        (0.0, -0.3),
        (radius * 0.86, -0.3),
        (radius, -0.05),
        (radius, height),
        (radius * 0.62, height + tip * 0.45),
        (0.0, height + tip),
    ]
    revolve(piece, profile, center=base, segments=6, rot=rot)


def build_gem_cluster():
    """Five faceted purple crystals (Crystal* pieces glow softly in game) on a lumpy rock base."""
    m = Model(
        "Shop_GemCluster",
        "ground centre under the rock base (y = 0); front faces -Z; shop viewport prop; 2.8 wide x 3.2 tall; "
        "Crystal* pieces = WorldFx soft glow (static)",
        budget=2000,
    )
    rock = m.piece("Rock", ROCK, material="StudsSmall")
    crystal = m.piece("Crystal", GEM_PURPLE, material="StudsSmall")
    deep = m.piece("CrystalDeep", GEM_DEEP, material="StudsSmall")
    pale = m.piece("CrystalPale", GEM_PALE, material="StudsSmall")
    shine = m.piece("Shine", SNOW, material="Smooth")
    sparkle = m.piece("Sparkle", (255, 250, 220), material="Neon")

    def lumpy(scale_y: float, floor: float):
        """Deterministic lumps (no randomness: rebuilds keep the same hash) + a flat bottom."""

        def deform(x, y, z):
            f = 1.0 + 0.1 * math.sin(3.1 * x + 1.3 * z) * math.cos(2.2 * z - 0.7 * x)
            return (x * f, max(y * f * scale_y, floor), z * f)

        return deform

    ellipsoid(rock, (0.0, 0.42, 0.0), (1.4, 0.62, 1.15), rings=6, segments=12, deform=lumpy(1.0, -0.42))
    for x, z, r in ((-1.25, -0.85, 0.28), (1.2, -0.75, 0.22), (0.95, 0.95, 0.25)):
        ellipsoid(rock, (x, r * 0.7, z), (r, r * 0.75, r * 0.9), rings=4, segments=7, deform=lumpy(1.0, -r * 0.7))

    _crystal(crystal, (0.0, 0.75, 0.05), (0.0, 1.0, 0.0), 0.44, 1.65, spin=10)  # hero crystal
    _crystal(pale, (-0.62, 0.6, 0.1), (-0.55, 1.0, 0.05), 0.3, 0.95, spin=25)
    _crystal(deep, (0.64, 0.6, -0.02), (0.6, 1.0, -0.15), 0.32, 1.05, spin=5)
    _crystal(deep, (-0.18, 0.62, -0.58), (-0.2, 1.0, -0.75), 0.24, 0.5, spin=40)
    _crystal(pale, (0.32, 0.65, 0.6), (0.3, 1.0, 0.6), 0.26, 0.75, spin=15)
    # Glint: a slim white stripe on the hero crystal's front-left facet + a tiny Neon sparkle star.
    facet = rot_y(10) @ Vector((math.cos(math.radians(-120)), 0, math.sin(math.radians(-120))))
    n = Vector((facet.x, 0, facet.z)).normalized()
    p = Vector((0.0, 1.55, 0.05)) + n * 0.4
    plate(shine, _rect(-0.05, -0.55, 0.05, 0.45), tuple(p), tuple(n), (0, 1, 0), 0.04)
    star(sparkle, (-0.75, 2.55, -0.35), 0.2, 0.05, normal=(0, 0, -1), inner_ratio=0.3)
    star(sparkle, (0.85, 2.15, -0.2), 0.13, 0.04, normal=(0, 0, -1), inner_ratio=0.3)
    return m


# ================================================================================================
# 3. Shop_SpinToken
# ================================================================================================

WEDGES = [
    ("WedgeRed", TOY_RED),
    ("WedgeOrange", ORANGE),
    ("WedgeYellow", YELLOW),
    ("WedgeLime", LIME),
    ("WedgeTeal", WEDGE_TEAL),
    ("WedgeBlue", SKY_BLUE),
    ("WedgePurple", PURPLE),
    ("WedgePink", PINK),
]


def build_spin_token():
    """Thick gold coin on its edge; both faces = 8-wedge rainbow prize wheel; hub, pegs, red pointer."""
    radius, thick = 1.42, 0.5
    cy = radius  # coin centre height (bottom of the rim touches the ground)
    m = Model(
        "Shop_SpinToken",
        f"ground point under the coin (rim touches y = 0); coin centre y = {cy:.2f}; wheel faces -Z and +Z; "
        "pointer on the top rim; shop viewport prop; spin about +Y",
        budget=2000,
    )
    rim = m.piece("Rim", TOY_GOLD, material="StudsSmall")
    shine = m.piece("RimShine", GOLD_LIGHT, material="Smooth")  # lighter bevel lines + star caps
    hub = m.piece("Hub", WHITE, material="StudsSmall")
    pointer = m.piece("Pointer", (220, 30, 48), material="StudsSmall")
    c = Vector((0, cy, 0))
    face_r = radius * 0.84
    # Rim: bevelled ring whose axis is Z (rot_x(90) turns the revolve's Y axis into +Z).
    b = 0.09
    revolve(
        rim,
        [
            (face_r - 0.04, -thick / 2),
            (radius - b, -thick / 2),
            (radius, -thick / 2 + b),
            (radius, thick / 2 - b),
            (radius - b, thick / 2),
            (face_r - 0.04, thick / 2),
        ],
        center=tuple(c),
        segments=32,
        closed=True,
        rot=rot_x(90),
    )
    # Wedges: pie slices through the coin (one plate shows on both faces), slightly inset from the rim.
    wedge_depth = thick * 0.72
    count = len(WEDGES)
    for k, (name, colour) in enumerate(WEDGES):
        piece = m.piece(name, colour, material="StudsSmall")
        a0 = 90 + 360 * k / count - 180 / count
        outline = [(0.0, 0.0)] + _arc(0.0, 0.0, face_r, face_r, a0, a0 + 360 / count, 4)
        plate(piece, outline, tuple(c), (0, 0, -1), (0, 1, 0), wedge_depth)
    # White dividers between wedges (stand proud of both faces), pegs at the rim, hub in the middle.
    for k in range(count):
        a = math.radians(90 + 360 * k / count - 180 / count)
        up = (math.cos(a), math.sin(a), 0.0)
        plate(hub, _rect(-0.035, 0.3, 0.035, face_r - 0.04), tuple(c), (0, 0, -1), up, wedge_depth + 0.07)
        pr = face_r - 0.13
        # plate-space x on a -Z plate is world -X, so flip x to put the peg on the divider line.
        peg = c + Vector((-math.cos(a) * pr, math.sin(a) * pr, 0))
        cylinder(hub, (peg.x, peg.y, -(wedge_depth / 2 + 0.12)), (peg.x, peg.y, wedge_depth / 2 + 0.12), 0.075, segments=8)
    revolve(
        hub,
        [(0.0, -0.36), (0.3, -0.36), (0.38, -0.26), (0.38, 0.26), (0.3, 0.36), (0.0, 0.36)],
        center=tuple(c),
        segments=16,
        rot=rot_x(90),
    )
    # Light-gold star cap on both faces of the hub, and a thin light-gold shine ring set into each
    # rim face (half buried) so the toy gold reads bright and polished instead of flat brown.
    for side in (-1, 1):
        star(shine, (0.0, cy, side * 0.38), 0.22, 0.06, normal=(0, 0, side), inner_ratio=0.45)
        ring_tube(shine, (0.0, cy, side * thick / 2), (face_r + radius - b) / 2, 0.06, 0.05, segments=32, axis="Z")
    # Pointer: rounded red flag on the top rim, tip pointing down into the wheel (both faces).
    outline = _arc(0.0, 0.16, 0.27, 0.27, -20, 200, 9) + [(0.0, -0.34)]
    plate(pointer, outline, (0, cy + radius - 0.04, 0), (0, 0, -1), (0, 1, 0), thick + 0.14)
    ellipsoid(pointer, (0, cy + radius + 0.2, 0), (0.11, 0.11, thick / 2 + 0.1), rings=4, segments=8)
    return m


# ================================================================================================
# 4. Shop_BoostPotion
# ================================================================================================


def build_boost_potion():
    """Round-bottom flask: Glass shell, Neon green `Liquid`, cork, fizz, starburst badge with "2x"."""
    m = Model(
        "Shop_BoostPotion",
        "ground centre under the flask (flat bottom at y = 0); front faces -Z ('2x' badge on the bulb "
        "front); bulb centre y = 1.06; shop viewport prop; Liquid = small Neon (WorldFx light)",
        budget=2000,
    )
    # 65 % transparent so the lime liquid reads vivid through the shell (45 % washed it to mint).
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.65)
    liquid = m.piece("Liquid", (150, 255, 40), material="Neon")  # bright lime "2x" green
    cork = m.piece("Cork", CORK, material="StudsSmall")
    fizz = m.piece("Fizz", GLOW_LIGHT, material="Smooth")
    badge = m.piece("Badge", YELLOW, material="StudsSmall")
    ink = m.piece("Ink", (214, 30, 46), material="Smooth")

    bc_y, rb_ = 1.12, 1.06  # bulb sphere centre height and radius
    neck = 0.36
    # Glass shell: flat foot, true-sphere bulb (so the badge can sit on it), neck and lip, closed top.
    profile = [(0.0, 0.06)]
    y_foot = 0.06
    a_foot = math.asin(max(-1.0, min(1.0, (y_foot - bc_y) / rb_)))
    a_neck = math.acos(neck / rb_)
    for i in range(11):
        a = a_foot + (a_neck - a_foot) * i / 10
        profile.append((rb_ * math.cos(a), bc_y + rb_ * math.sin(a)))
    neck_y = profile[-1][1]
    profile += [(neck, neck_y + 0.62), (0.47, neck_y + 0.66), (0.47, neck_y + 0.8), (0.3, neck_y + 0.84), (0.0, neck_y + 0.84)]
    revolve(glass, profile, segments=20)
    # Liquid: the bulb filled to just above its equator, a little inside the glass.
    surface_y = bc_y + 0.28
    inner = rb_ - 0.07
    lprofile = [(0.0, 0.13)]
    # The liquid floor sits exactly at the inner sphere's bottom (0.13 = bc_y - inner), so clamp
    # the ratio: float rounding would otherwise push it just past -1 (math domain error).
    a0 = math.asin(max(-1.0, (0.13 - bc_y) / inner))
    a1 = math.asin((surface_y - bc_y) / inner)
    for i in range(8):
        a = a0 + (a1 - a0) * i / 7
        lprofile.append((inner * math.cos(a), bc_y + inner * math.sin(a)))
    lprofile.append((0.0, surface_y))
    revolve(liquid, lprofile, segments=20)
    # Fizz: three bubbles floating above the liquid inside the glass.
    for x, y, z, r in ((-0.3, surface_y + 0.22, -0.2, 0.1), (0.22, surface_y + 0.42, 0.1, 0.08), (0.05, surface_y + 0.7, -0.08, 0.06)):
        ellipsoid(fizz, (x, y, z), (r, r, r), rings=4, segments=8)
    # Cork: sits in the neck (visible through the glass) and pops out above the lip.
    top = neck_y + 0.84
    revolve(cork, [(0.0, top - 0.42), (0.31, top - 0.42), (0.34, top + 0.22), (0.31, top + 0.3), (0.0, top + 0.32)], segments=12)
    # Badge: a 14-point starburst curved onto the bulb front, then a bold red "2x" on top of it.
    badge_c = (0.0, bc_y - 0.08, 0.0)
    outline = _starburst(0.7, 0.58, 14)
    _sphere_patch(badge, [(x, y - 0.08) for x, y in outline], (0, bc_y, 0), rb_, -0.03, 0.06, side=-1)
    # Glyphs: flat, deep enough that their backs stay buried in the curved badge at the edges.
    origin = (badge_c[0], badge_c[1], -(rb_ + 0.12))
    h = 0.6
    _glyph(ink, _two(h), origin, (0, 0, -1), 0.24, dx=-0.2, dy=0.04)
    _glyph(ink, _letter_x(h), origin, (0, 0, -1), 0.24, dx=0.23, dy=0.04)
    # A small matching badge on the back so the spinning prop never shows a bare side.
    _sphere_patch(badge, _starburst(0.42, 0.34, 10), (0, bc_y, 0), rb_, -0.03, 0.05, side=1)
    # Authored with the flat foot at y = 0.06 (bulb maths above); drop it onto the pivot plane.
    _ground(m)
    return m


# ================================================================================================
# 5. Shop_MoneyBag
# ================================================================================================

BAG_PROFILE = [
    (0.0, 0.0),
    (0.78, 0.0),
    (1.16, 0.12),
    (1.38, 0.45),
    (1.46, 0.9),
    (1.41, 1.35),
    (1.22, 1.75),
    (0.88, 2.06),
    (0.52, 2.26),
    (0.34, 2.4),
    (0.0, 2.44),
]


def build_money_bag():
    """Plump tan sack, frilled top, rope + bow at the neck, big wrapped "$", back patch, gold coins."""
    m = Model(
        "Shop_MoneyBag",
        "ground centre under the sack (y = 0); '$' faces -Z, patch on the back; shop viewport prop; "
        "2.9 wide x 3.1 tall",
        budget=2000,
    )
    bag = m.piece("Bag", BAG_TAN, material="StudsSmall")
    rope = m.piece("Rope", ROPE_BROWN, material="StudsSmall")
    ink = m.piece("Ink", INK_GREEN, material="StudsSmall")
    patch = m.piece("Patch", BAG_PATCH, material="StudsSmall")
    coins = m.piece("Coins", TOY_GOLD, material="StudsSmall")

    revolve(bag, BAG_PROFILE, segments=20)
    # Frilled gathered top: loft from inside the neck out to a wavy rim, then dip back to a centre
    # point (a shallow cloth dish), so it reads as fabric bunched above the rope.
    seg = 32

    def ring(y: float, r: float, wave: float) -> list:
        return [
            (
                (r + wave * math.cos(8 * 2 * math.pi * i / seg)) * math.cos(2 * math.pi * i / seg),
                y + wave * 0.6 * math.cos(8 * 2 * math.pi * i / seg),
                (r + wave * math.cos(8 * 2 * math.pi * i / seg)) * math.sin(2 * math.pi * i / seg),
            )
            for i in range(seg)
        ]

    sections = [ring(2.3, 0.3, 0.0), ring(2.55, 0.36, 0.03), ring(2.8, 0.62, 0.08), ring(2.94, 0.66, 0.09), ring(2.92, 0.52, 0.06)]
    made = loft(bag, sections, cap_start=True, cap_end=False)
    # Dish: fan from the last ring down to a centre point.
    last = made[len(made) - seg :]
    centre = bag.bm.verts.new(rb((0.0, 2.8, 0.0)))
    for i in range(seg):
        try:
            bag.bm.faces.new([last[(i + 1) % seg], last[i], centre])
        except ValueError:
            pass
    # Rope: a fat ring round the neck + a bow (two loops and two tails) on the front.
    neck_y = 2.42
    rr = 0.42
    tube(rope, [(rr * math.cos(2 * math.pi * i / 16), neck_y, rr * math.sin(2 * math.pi * i / 16)) for i in range(16)], 0.1, sides=6, closed=True)
    for sx in (-1, 1):
        loop = [
            (sx * 0.05, neck_y, -rr - 0.05),
            (sx * 0.3, neck_y + 0.18, -rr - 0.16),
            (sx * 0.52, neck_y + 0.1, -rr - 0.14),
            (sx * 0.5, neck_y - 0.1, -rr - 0.1),
            (sx * 0.25, neck_y - 0.06, -rr - 0.06),
            (sx * 0.05, neck_y, -rr - 0.05),
        ]
        tube(rope, loop, 0.075, sides=6)
        tail = [(sx * 0.05, neck_y - 0.02, -rr - 0.06), (sx * 0.2, neck_y - 0.3, -rr - 0.12), (sx * 0.3, neck_y - 0.55, -rr - 0.2)]
        tube(rope, tail, 0.07, sides=6)
        ellipsoid(rope, tail[-1], (0.09, 0.09, 0.09), rings=3, segments=6)
    ellipsoid(rope, (0, neck_y, -rr - 0.06), (0.13, 0.12, 0.11), rings=4, segments=8)  # knot

    # Big "$" on the front, wrapped onto the bag's curvature (flat glyph -> follows the surface).
    def front_z(x: float, y: float) -> float:
        r = _profile_radius(BAG_PROFILE, min(max(y, 0.05), 2.3))
        return -math.sqrt(max(r * r - x * x, 0.01))

    glyph_y = 1.08
    ref = front_z(0.0, glyph_y)
    start = len(ink.bm.verts)
    _glyph(ink, _dollar(1.2), (0.0, glyph_y, ref - 0.02), (0, 0, -1), 0.2)
    _wrap_z(ink, start, front_z, ref)

    # Stitched patch on the back (+Z), wrapped onto the bag, with darker stitch dashes.
    def back_z(x: float, y: float) -> float:
        return -front_z(x, y)

    patch_c = (-0.35, 0.95)
    ref_b = back_z(*patch_c)
    start = len(patch.bm.verts)
    plate(patch, _rect(-0.4, -0.34, 0.4, 0.34), (patch_c[0], patch_c[1], ref_b + 0.02), (0, 0, 1), (0.2, 1, 0), 0.12)
    _wrap_z(patch, start, back_z, ref_b)
    start = len(rope.bm.verts)
    for i in range(4):
        t = -0.27 + 0.18 * i
        for dx, dy, w, h in ((t, 0.3, 0.1, 0.035), (t, -0.3, 0.1, 0.035), (0.36, t, 0.035, 0.1), (-0.36, t, 0.035, 0.1)):
            plate(rope, _rect(dx - w / 2, dy - h / 2, dx + w / 2, dy + h / 2), (patch_c[0], patch_c[1], ref_b + 0.07), (0, 0, 1), (0.2, 1, 0), 0.06)
    _wrap_z(rope, start, back_z, ref_b)

    # Gold coins spilling at the front: one flat, one leaning on the bag, a little stack of two.
    _coin(coins, (0.95, 0.06, -1.25), 0.34, 0.12)
    _coin(coins, (0.95, 0.18, -1.25), 0.34, 0.12, rot=rot_y(15))
    _coin(coins, (-1.12, 0.38, -1.02), 0.34, 0.12, rot=rot_y(30) @ rot_x(-65))
    return m


# ================================================================================================
# 6. Shop_VipCrown
# ================================================================================================


def build_vip_crown():
    """Flared five-point gold crown, light-gold jewelled band, pearl tips, velvet cushion + gold orb."""
    m = Model(
        "Shop_VipCrown",
        "ground centre under the crown (band bottom at y = 0); one point and the red jewel face -Z; "
        "shop viewport prop; 3.0 wide x 2.5 tall",
        budget=2000,
    )
    crown = m.piece("Crown", TOY_GOLD, material="StudsSmall")
    band = m.piece("Band", GOLD_LIGHT, material="StudsSmall")  # lighter bevelled band (not brown)
    velvet = m.piece("Velvet", VELVET, material="StudsSmall")
    pearls = m.piece("Pearls", SNOW, material="Smooth")
    jewels = {
        "red": m.piece("JewelRed", JEWEL_RED, material="Smooth"),
        "blue": m.piece("JewelBlue", JEWEL_BLUE, material="Smooth"),
        "green": m.piece("JewelGreen", JEWEL_GREEN, material="Smooth"),
    }
    r0, wall = 1.2, 0.16  # base outer radius, wall thickness
    band_h, spike_h = 0.75, 1.15
    flare = 0.2  # extra radius at the top of the points (the crown opens upward)
    seg = 40  # 8 per point: peaks at i = 0, 8, ..; valleys at i = 4, 12, ..

    def height(i: int) -> float:
        k = i % 8
        dist = min(k, 8 - k) / 4.0  # 0 at a peak, 1 at a valley
        return band_h + spike_h * (1.0 - dist) ** 1.25

    def radius_at(y: float) -> float:
        return r0 + flare * y / (band_h + spike_h)

    verts = []
    for i in range(seg):
        a = -math.pi / 2 + 2 * math.pi * i / seg  # i = 0 faces -Z
        ca, sa = math.cos(a), math.sin(a)
        h = height(i)
        for r, y in ((radius_at(0.0), 0.0), (radius_at(h), h), (radius_at(h) - wall, h), (radius_at(0.0) - wall, 0.0)):
            verts.append((r * ca, y, r * sa))
    faces = []
    for i in range(seg):
        j = (i + 1) % seg
        a, b = 4 * i, 4 * j
        for k in range(4):
            k2 = (k + 1) % 4
            faces.append((a + k, b + k, b + k2, a + k2))
    add_faces(crown, verts, faces)
    # Gold orb on top of the cushion.
    ellipsoid(crown, (0.0, 1.62, 0.0), (0.2, 0.2, 0.2), rings=5, segments=10)
    # Base band: a raised bevelled ring that the jewels sit in.
    rb0 = radius_at(0.0)
    revolve(
        band,
        [(rb0 - 0.05, 0.0), (rb0 + 0.1, 0.0), (rb0 + 0.15, 0.06), (rb0 + 0.15, 0.5), (rb0 + 0.1, 0.56), (rb0 - 0.05, 0.56)],
        segments=seg,
        closed=True,
    )
    # Velvet cushion dome filling the crown (shows between the points from above).
    revolve(velvet, [(0.0, 0.2), (r0 - wall - 0.02, 0.2), (r0 - wall - 0.04, 0.8), (0.82, 1.22), (0.45, 1.45), (0.0, 1.5)], segments=20)
    # Jewels on the band under each point (front = big red), pearls on every tip.
    order = ["red", "blue", "green", "green", "blue"]
    for k in range(5):
        a = -math.pi / 2 + 2 * math.pi * k / 5
        n = Vector((math.cos(a), 0.0, math.sin(a)))
        size = 0.2 if k == 0 else 0.15
        p = n * (rb0 + 0.15) + Vector((0, 0.28, 0))
        oriented_ellipsoid(jewels[order[k]], tuple(p), (size, size * 1.2, 0.08), normal=tuple(n), rings=4, segments=8)
        tip_y = band_h + spike_h
        tip = n * (radius_at(tip_y) - wall / 2) + Vector((0, tip_y + 0.08, 0))
        ellipsoid(pearls, tuple(tip), (0.15, 0.15, 0.15), rings=5, segments=10)
        # A small round pearl in each valley along the band top as well.
        av = a + math.pi / 5
        nv = Vector((math.cos(av), 0.0, math.sin(av)))
        ellipsoid(pearls, tuple(nv * (rb0 + 0.15) + Vector((0, 0.28, 0))), (0.08, 0.08, 0.08), rings=4, segments=8)
    return m


# ================================================================================================
# 7. Shop_ServerBoost
# ================================================================================================


def build_server_boost():
    """Blue coin on its edge with a chubby cartoon rocket bursting through it + yellow lightning bolts."""
    radius, thick = 1.38, 0.38
    cy = radius
    m = Model(
        "Shop_ServerBoost",
        f"ground point under the coin (rim touches y = 0); coin centre y = {cy:.2f}; faces -Z and +Z; rocket "
        "flies up toward the viewer's right (front view) through the coin; shop viewport prop; spin about +Y",
        budget=2000,
    )
    rim = m.piece("Rim", COIN_RIM_BLUE, material="StudsSmall")
    face = m.piece("Face", COIN_FACE_BLUE, material="StudsSmall")
    ship = m.piece("Ship", WHITE, material="StudsSmall")
    trim = m.piece("ShipTrim", TOY_RED, material="StudsSmall")
    porthole = m.piece("Porthole", PORTHOLE, material="Smooth")
    bolt = m.piece("Bolt", YELLOW, material="StudsSmall")
    exhaust = m.piece("Exhaust", ORANGE, material="Neon")
    exhaust_core = m.piece("ExhaustCore", YELLOW, material="Neon")

    c = Vector((0.0, cy, 0.0))
    face_r = radius * 0.82
    b = 0.08
    revolve(
        rim,
        [
            (face_r - 0.04, -thick / 2),
            (radius - b, -thick / 2),
            (radius, -thick / 2 + b),
            (radius, thick / 2 - b),
            (radius - b, thick / 2),
            (face_r - 0.04, thick / 2),
        ],
        center=tuple(c),
        segments=28,
        closed=True,
        rot=rot_x(90),
    )
    revolve(face, [(0.0, -thick * 0.36), (face_r, -thick * 0.36), (face_r, thick * 0.36), (0.0, thick * 0.36)], center=tuple(c), segments=28, rot=rot_x(90))
    # Rocket axis: rot_z(55) maps +Y to (-0.82, 0.57, 0): up and toward -X = the viewer's right.
    rot = rot_z(55)
    axis = rot @ Vector((0, 1, 0))
    side = rot @ Vector((1, 0, 0))  # in the coin plane, perpendicular to the axis
    rc = c + axis * 0.18  # rocket centre (nudged so the nose clears the rim)
    body_r = 0.47
    revolve(
        ship,
        [(0.0, -1.0), (0.3, -1.0), (0.4, -0.88), (body_r, -0.5), (body_r, 0.3), (0.43, 0.55), (0.0, 0.55)],
        center=tuple(rc),
        segments=14,
        rot=rot,
    )
    revolve(trim, [(0.0, 0.5), (0.44, 0.5), (0.39, 0.8), (0.27, 1.08), (0.1, 1.28), (0.0, 1.32)], center=tuple(rc), segments=14, rot=rot)
    # Nozzle bell under the tail.
    revolve(trim, [(0.0, -0.98), (0.26, -0.98), (0.33, -1.2), (0.0, -1.2)], center=tuple(rc), segments=12, rot=rot)
    # Four fins in an X (45 deg off the coin plane) so they stick out of BOTH faces.
    for k in range(4):
        ang = math.radians(45 + 90 * k)
        radial = side * math.cos(ang) + Vector((0, 0, 1)) * math.sin(ang)
        normal = axis.cross(radial)
        # plate local +x = up x normal = -radial (see _critter_kit.frame), so negate the radial coord.
        fin = [(-0.3, -0.25), (-0.86, -0.82), (-0.88, -1.18), (-0.3, -0.98)]
        plate(trim, fin, tuple(rc), tuple(normal), tuple(axis), 0.1)
    # Portholes front and back: red ring + navy window, buried in the curved body at the edges.
    for s in (-1, 1):
        p = rc + axis * 0.05
        revolve(trim, [(0.0, 0.0), (0.27, 0.0), (0.27, 0.16), (0.0, 0.16)], center=(p.x, p.y, s * (body_r - 0.1)), segments=12, rot=rot_x(-90 * s))
        revolve(porthole, [(0.0, 0.0), (0.19, 0.0), (0.19, 0.2), (0.0, 0.2)], center=(p.x, p.y, s * (body_r - 0.1)), segments=12, rot=rot_x(-90 * s))
    # Flame: yellow core at the nozzle, orange teardrop beyond it (both point away from the nose).
    back = rot_z(55 + 180)
    tail = rc - axis * 1.18
    revolve(exhaust_core, [(0.0, -0.02), (0.26, 0.06), (0.3, 0.24), (0.18, 0.46), (0.0, 0.56)], center=tuple(tail), segments=10, rot=back)
    t2 = tail - axis * 0.16
    revolve(exhaust, [(0.0, 0.06), (0.36, 0.18), (0.38, 0.42), (0.24, 0.72), (0.0, 0.95)], center=tuple(t2), segments=10, rot=back)
    # Lightning bolts on both faces in the free corner (+X +Y: viewer's upper-left on the front).
    zig = [(-0.12, 0.42), (0.2, 0.42), (0.04, 0.1), (0.22, 0.1), (-0.2, -0.46), (-0.06, -0.06), (-0.24, -0.06)]
    for s in (-1, 1):
        # Front (-Z) plate: +x is world -X, so mirror x to keep the bolt leaning the same way in the world.
        outline = [(-x, y) for x, y in zig] if s < 0 else zig
        plate(bolt, outline, (0.62, cy + 0.5, s * (thick * 0.36 + 0.02)), (0, 0, s), (0.25, 1, 0), 0.08)
    return m


# ================================================================================================
# Batch 2 helpers (cash pile, gem chest, teleporter, shoe, clicker, moon, pet slots, triple egg)
# ================================================================================================

# Extra shop colours for batch 2 (same candy palette rules as above).
SHOE_BLUE = (64, 150, 240)
HAND_YELLOW = (255, 212, 28)
CUFF_BLUE = (70, 130, 230)
MOON_YELLOW = (255, 234, 32)  # bright lemon
MOON_CRATER = (255, 186, 20)  # saturated golden craters (never brown)
ZZZ_PURPLE = (112, 46, 222)  # deep purple "Zzz"
PAD_SLATE = (72, 80, 118)
PAD_TOP = (70, 196, 222)
TAG_FACE = CREAM
TAG_RIM = (255, 52, 170)  # bright pink-magenta
PAW_BROWN = (110, 70, 46)
PLUS_GREEN = (52, 204, 92)
EGG_PINK = (255, 90, 172)  # three candy eggs, each its own bright colour
EGG_BLUE = (44, 168, 255)
EGG_MINT = (52, 218, 116)
SPOT_YELLOW = (255, 232, 36)  # spots contrast with all three shells
STRAW = (255, 204, 52)  # sunny straw
STRAW_DARK = (246, 148, 34)  # warm orange nest bowl


def _recentre(m) -> None:
    """
    Move every piece so the model's bounding box is centred on X / Z and its lowest point sits at
    y = 0 (the pivot contract). Asymmetric props (shoe with wings, hand + cursor, crescent + Zzz) use
    it so the shop turntable spins them about their middle instead of wobbling around an off-centre
    pivot.

    Example: _recentre(m)  # after all geometry is added, before `return m`
    """
    lo, hi = model_bounds(m)
    transform_model(m, offset=(-(lo[0] + hi[0]) / 2, -lo[1], -(lo[2] + hi[2]) / 2))


def _ground(m) -> None:
    """
    Lift / drop every piece so the model's lowest point sits exactly at y = 0, without touching X / Z
    (props whose spin axis should stay on their main body, e.g. the potion's bulb, use this instead
    of _recentre).
    """
    lo, _ = model_bounds(m)
    transform_model(m, offset=(0.0, -lo[1], 0.0))


def _capsule(piece, a, b, radius: float, segments: int = 10, rings: int = 2):
    """
    Rounded rod with hemispherical ends from point a to point b (fingers, laces, straw, click
    dashes): one revolve about the a->b axis, watertight, ~segments * (4 * rings) triangles.

    Example: _capsule(skin, (0, 1, 0), (0, 2.5, 0), 0.22)  # upright finger, 1.5 + 2r long
    """
    a, b = Vector(a), Vector(b)
    d = b - a
    length = d.length
    rot = Vector((0, 1, 0)).rotation_difference(d.normalized()).to_matrix()
    profile = [(0.0, -radius)]
    for i in range(1, rings + 1):
        t = math.radians(-90 + 90 * i / rings)
        profile.append((radius * math.cos(t), radius * math.sin(t)))
    for i in range(rings):
        t = math.radians(90 * i / rings)
        profile.append((radius * math.cos(t), length + radius * math.sin(t)))
    profile.append((0.0, length + radius))
    revolve(piece, profile, center=tuple(a), segments=segments, rot=rot)


def _offset_outline(outline: list, d: float) -> list:
    """
    Grow a simple 2-D polygon outward by d with mitred corners (miter clamped to 3 d so sharp tips
    stay short). Used for the dark rim behind the cursor arrow and the white border of the "+".

    Example: _offset_outline(_rect(0, 0, 1, 1), 0.1) -> the square (-0.1, -0.1) .. (1.1, 1.1)
    """
    n = len(outline)
    area = sum(outline[i][0] * outline[(i + 1) % n][1] - outline[(i + 1) % n][0] * outline[i][1] for i in range(n))
    sign = 1.0 if area > 0 else -1.0  # CCW: the outward normal of edge (dx, dy) is (dy, -dx)

    def edge_normal(ax: float, ay: float, bx: float, by: float) -> tuple:
        length = math.hypot(bx - ax, by - ay) or 1.0
        return (sign * (by - ay) / length, -sign * (bx - ax) / length)

    out = []
    for i in range(n):
        px, py = outline[i - 1]
        cx, cy = outline[i]
        qx, qy = outline[(i + 1) % n]
        n1 = edge_normal(px, py, cx, cy)
        n2 = edge_normal(cx, cy, qx, qy)
        mx, my = n1[0] + n2[0], n1[1] + n2[1]
        ml = math.hypot(mx, my)
        if ml < 1e-6:
            mx, my, ml = n1[0], n1[1], 1.0
        mx, my = mx / ml, my / ml
        cos_half = mx * n1[0] + my * n1[1]
        scale = d / max(cos_half, 1.0 / 3.0)
        out.append((cx + mx * scale, cy + my * scale))
    return out


def _letter_z(h: float) -> list:
    """A bold "Z" outline of height h centred on (0, 0) (sleepy "Zzz" on the offline moon)."""
    w, t = h * 0.8, h * 0.24
    return [
        (-w / 2, h / 2),
        (w / 2, h / 2),
        (w / 2, h / 2 - t),
        (-w / 2 + t * 1.25, -h / 2 + t),
        (w / 2, -h / 2 + t),
        (w / 2, -h / 2),
        (-w / 2, -h / 2),
        (-w / 2, -h / 2 + t),
        (w / 2 - t * 1.25, h / 2 - t),
        (-w / 2, h / 2 - t),
    ]


def _diamond(piece, center, size: float, normal=(0, 1, 0), spin: float = 0.0, segments: int = 8):
    """
    Brilliant-cut gem (the classic "gem" icon shape): pointed culet, girdle band, sloped crown and a
    flat table. `center` = girdle centre, `normal` = the way the table faces, size = girdle diameter.
    8 segments -> 48 triangles.

    Example: _diamond(gem, (0, 1.6, -0.3), 0.6, normal=(0, 0.4, -1))  # table toward the viewer
    """
    r = size / 2
    profile = [(0.0, -size * 0.55), (r, 0.0), (r, size * 0.07), (r * 0.6, size * 0.3), (0.0, size * 0.3)]
    rot = Vector((0, 1, 0)).rotation_difference(Vector(normal).normalized()).to_matrix() @ rot_y(spin)
    revolve(piece, profile, center=tuple(center), segments=segments, rot=rot)


def _bundle(pieces: tuple, base, yaw: float, size: tuple, dollar_sides: tuple = ()):
    """
    One banknote bundle standing on `base` (its bottom centre): a dark lower block of notes, a light
    top block nudged a little sideways (reads as separate bills), a cream paper band, and a small
    "$" on the band's local -Z (side -1) and / or +Z (side +1) face. pieces = (notes, dark, band, ink).
    ~132 tris + ~96 per "$".

    Example: _bundle((notes, dark, band, ink), (0, 0, 0), 5, (2.0, 0.52, 0.95), dollar_sides=(-1,))
    """
    notes, dark, band, ink = pieces
    length, height, depth = size
    rot = rot_y(yaw)
    bx, by, bz = base
    lower = height * 0.58
    block(dark, (bx, by + lower / 2, bz), (length, lower, depth), bevel=0.05, rot=rot)
    nudge = rot @ Vector((0.04, 0.0, -0.03))
    top_c = (bx + nudge.x, by + lower + (height - lower) / 2, bz + nudge.z)
    block(notes, top_c, (length - 0.04, height - lower, depth - 0.04), bevel=0.05, rot=rot @ rot_y(1.5))
    c = Vector((bx, by + height / 2, bz))
    # Band: flush with the bundle's base (never below the ground), 0.03 proud on top.
    block(band, (bx, by + (height + 0.03) / 2, bz), (0.62, height + 0.03, depth + 0.1), bevel=0.04, rot=rot)
    for side in dollar_sides:
        n = rot @ Vector((0, 0, side))
        origin = c + n * ((depth + 0.1) / 2 + 0.02)
        # 0.74 x height keeps the "$" bar inside the band (nothing below the bundle's base).
        _glyph(ink, _dollar(height * 0.74, steps=5), tuple(origin), tuple(n), 0.06)


# ================================================================================================
# 8. Shop_CashPile
# ================================================================================================


def build_cash_pile():
    """Big pyramid of seven banded bundles (2 x 2 base, crosswise middle pair, top bundle) + coins."""
    m = Model(
        "Shop_CashPile",
        "ground centre under the pile (bottom bundles at y = 0); front faces -Z; shop viewport prop for "
        "cash packs; ~4.1 wide x 1.6 tall; '$' bands on every side",
        budget=2000,
    )
    notes = m.piece("Notes", NOTE_GREEN, material="StudsSmall")
    dark = m.piece("NotesDark", NOTE_DARK, material="StudsSmall")
    band = m.piece("Band", CREAM, material="StudsSmall")
    ink = m.piece("Ink", INK_GREEN, material="Smooth")
    coins = m.piece("Coins", TOY_GOLD, material="StudsSmall")
    pieces = (notes, dark, band, ink)

    size = (2.0, 0.52, 0.95)  # one bundle: length (x) x height x depth (z)
    h = size[1]
    # Bottom tier: a 2 x 2 grid, small yaw jitter so it reads hand-stacked. "$" on the outer faces.
    _bundle(pieces, (-1.03, 0.0, -0.52), 3.0, size, dollar_sides=(-1,))
    _bundle(pieces, (1.04, 0.0, -0.5), -4.0, size, dollar_sides=(-1,))
    _bundle(pieces, (-1.0, 0.0, 0.5), -3.0, size)
    _bundle(pieces, (1.05, 0.0, 0.52), 4.0, size)
    # Middle tier: two bundles laid crosswise (brick bond); yaw ~90 turns their bands to face +-X.
    _bundle(pieces, (-0.52, h, 0.0), 87.0, size, dollar_sides=(-1,))  # local -Z -> world -X
    _bundle(pieces, (0.55, h, 0.02), 94.0, size, dollar_sides=(1,))  # local +Z -> world +X
    # Top bundle with a "$" front and back.
    _bundle(pieces, (0.0, 2 * h, -0.05), 10.0, size, dollar_sides=(-1, 1))
    # Coins: a short stack in front, one flat coin at the back corner, one leaning on the front-left.
    for k, (dx, dz) in enumerate(((0.0, 0.0), (0.04, -0.03), (-0.03, 0.02))):
        _coin(coins, (-0.15 + dx, 0.06 + 0.12 * k, -1.38 + dz), 0.36, 0.12, segments=12)
    _coin(coins, (1.62, 0.06, 1.25), 0.34, 0.12, segments=12)
    _coin(coins, (1.35, 0.4, -1.12), 0.36, 0.12, segments=12, rot=rot_y(15) @ rot_x(-68))
    return m


# ================================================================================================
# 9. Shop_GemChest
# ================================================================================================


def build_gem_chest():
    """Open wooden treasure chest with gold straps, heaped with brilliant-cut purple gems."""
    m = Model(
        "Shop_GemChest",
        "ground centre under the chest (y = 0); lock + gems face -Z, lid hinged open at the back (+Z); "
        "shop viewport prop for gem packs; ~2.6 wide x 2.8 tall; Crystal piece = WorldFx soft glow",
        budget=2000,
    )
    wood = m.piece("Wood", WOOD, material="StudsSmall")
    seams = m.piece("WoodDark", WOOD_DARK, material="Smooth")
    trim = m.piece("Trim", TOY_GOLD, material="StudsSmall")
    lock = m.piece("Lock", GOLD_LIGHT, material="StudsSmall")
    keyhole = m.piece("Keyhole", SOFT_BLACK, material="Smooth")
    heap = m.piece("GemHeap", GEM_DEEP, material="StudsSmall")
    gem = m.piece("Crystal", GEM_PURPLE, material="StudsSmall")
    gem_pale = m.piece("GemPale", GEM_PALE, material="StudsSmall")
    shine = m.piece("Shine", SNOW, material="Smooth")
    sparkle = m.piece("Sparkle", (255, 250, 220), material="Neon")

    width, depth, height = 2.5, 1.6, 1.2
    # Body + plank seams (thin dark slabs poking 0.015 through the front and back faces).
    block(wood, (0.0, height / 2, 0.0), (width, height, depth), bevel=0.1)
    for y in (0.42, 0.8):
        block(seams, (0.0, y, 0.0), (width - 0.1, 0.05, depth + 0.03), bevel=0.0)
    # Gold bands (bottom + top rim) and two straps that wrap front, bottom and back.
    for y in (0.08, height - 0.06):
        block(trim, (0.0, y, 0.0), (width + 0.08, 0.16, depth + 0.08), bevel=0.04)
    for x in (-0.8, 0.8):
        block(trim, (x, height / 2, 0.0), (0.2, height, depth + 0.08), bevel=0.04)
    # Lock plate + keyhole on the front.
    block(lock, (0.0, 0.86, -depth / 2 - 0.04), (0.46, 0.5, 0.12), bevel=0.05)
    oriented_ellipsoid(keyhole, (0.0, 0.92, -depth / 2 - 0.1), (0.07, 0.07, 0.03), normal=(0, 0, -1), rings=3, segments=8)
    block(keyhole, (0.0, 0.8, -depth / 2 - 0.1), (0.06, 0.16, 0.04), bevel=0.0)

    # Lid: a half-ellipse arch (closed position: spans z -0.8..0.8 on the body top, 0.62 tall),
    # rotated 108 deg about the back hinge so it stands open, leaning slightly back.
    hinge = Vector((0.0, height, depth / 2))
    open_rot = rot_x(108)

    def opened(y: float, z: float, x: float = 0.0) -> tuple:
        q = hinge + open_rot @ (Vector((x, y, z)) - hinge)
        return (q.x, q.y, q.z)

    def arch(scale_y: float, scale_z: float) -> list:
        return [(height + 0.62 * scale_y * math.sin(math.pi * k / 12), depth / 2 * scale_z * math.cos(math.pi * k / 12)) for k in range(13)]

    prism(wood, [opened(y, z) for y, z in arch(1.0, 1.0)], (1, 0, 0), width)
    for x in (-0.8, 0.8):
        prism(trim, [opened(y, z, x) for y, z in arch(1.1, 1.05)], (1, 0, 0), 0.2)
    # Darker lid lining (faces the viewer once open) + a gold hasp hanging off the lid's front edge.
    block(seams, opened(height - 0.01, 0.0), (width - 0.16, 0.04, depth - 0.12), bevel=0.0, rot=open_rot)
    block(lock, opened(height + 0.12, -depth / 2 - 0.04), (0.34, 0.3, 0.1), bevel=0.04, rot=open_rot)

    # Gem heap: a deep-purple mound filling the chest, crowned with faceted gems facing every way.
    def flat_bottom(x, y, z):
        return (x, max(y, -0.3), z)

    ellipsoid(heap, (0.0, 1.12, -0.02), (1.12, 0.42, 0.7), rings=5, segments=12, deform=flat_bottom)
    gems = [
        (gem, (0.0, 1.62, -0.28), 0.64, (0.0, 0.45, -1.0), 0),
        (gem_pale, (-0.62, 1.5, -0.22), 0.46, (-0.4, 0.6, -0.8), 10),
        (gem, (0.62, 1.5, -0.18), 0.48, (0.45, 0.6, -0.8), 20),
        (gem, (-0.36, 1.6, 0.3), 0.42, (-0.3, 1.0, 0.4), 5),
        (gem_pale, (0.4, 1.62, 0.32), 0.4, (0.3, 1.0, 0.5), 15),
        (gem, (0.96, 1.36, 0.3), 0.36, (0.8, 0.6, 0.3), 0),
        (gem_pale, (-0.96, 1.36, 0.22), 0.38, (-0.8, 0.6, 0.2), 0),
        (gem, (0.0, 1.55, 0.42), 0.5, (0.0, 0.5, 1.0), 0),
        # Spilled in front of the chest: one standing on its girdle, one lying table-up.
        (gem_pale, (0.86, 0.27, -1.12), 0.48, (0.25, 0.3, -1.0), 0),
        (gem, (-0.78, 0.23, -1.05), 0.42, (-0.2, 1.0, -0.2), 0),
    ]
    for piece, c, size, n, spin in gems:
        _diamond(piece, c, size, normal=n, spin=spin)
    # White glints on the hero gem's table and the spilled pale gem, + two Neon sparkle stars.
    plate(shine, _rect(-0.05, -0.12, 0.05, 0.12), (0.1, 1.73, -0.4), (0.0, 0.45, -1.0), (0, 1, 0), 0.03)
    plate(shine, _rect(-0.04, -0.09, 0.04, 0.09), (0.82, 0.32, -1.22), (0.25, 0.3, -1.0), (0, 1, 0), 0.03)
    star(sparkle, (-0.55, 2.05, -0.55), 0.18, 0.05, normal=(0, 0, -1), inner_ratio=0.3)
    star(sparkle, (0.75, 1.95, -0.45), 0.12, 0.04, normal=(0, 0, -1), inner_ratio=0.3)
    return m


# ================================================================================================
# 10. Shop_Teleporter
# ================================================================================================


def build_teleporter():
    """Round sci-fi teleporter pad: hazard-striped base, spiral top, Neon ring, glass beam, floating hoops."""
    m = Model(
        "Shop_Teleporter",
        "ground centre under the pad (y = 0); round, reads from every yaw; shop viewport prop for the "
        "Teleporter pass; 3.1 wide x 2.9 tall; Ring / Beam / Sparkle = small Neon (each under NeonMaxArea)",
        budget=2000,
    )
    base = m.piece("Base", PAD_SLATE, material="StudsSmall")
    top = m.piece("PadTop", PAD_TOP, material="StudsSmall")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW, material="StudsSmall")
    black = m.piece("HazardBlack", HAZARD_BLACK, material="StudsSmall")
    ring = m.piece("Ring", SKY_GLOW, material="Neon")
    swirl = m.piece("Swirl", DEEP_BLUE, material="Smooth")
    beam = m.piece("Beam", SKY_GLOW, material="Neon", transparency=0.62)  # soft light column (3.6 studs² face)
    hoops = m.piece("Hoops", YELLOW, material="StudsSmall")
    tips = m.piece("Tips", SKY_GLOW, material="Smooth")
    sparkle = m.piece("Sparkle", (255, 250, 220), material="Neon")

    # Chunky bevelled base with a yellow/black hazard band around its side.
    revolve(base, [(0.0, 0.0), (1.42, 0.0), (1.5, 0.08), (1.5, 0.34), (1.42, 0.42), (0.0, 0.42)], segments=24)
    hazard_ring(yellow, black, (0, 0, 0), 1.46, 1.54, 0.13, 0.3, count=16, slices=2)
    # Teal top disc, Neon ring just inside its edge, and a blue spiral decal (the teleport swirl).
    revolve(top, [(0.0, 0.36), (1.18, 0.36), (1.24, 0.42), (1.24, 0.46), (1.18, 0.52), (0.0, 0.52)], segments=24)
    ring_tube(ring, (0.0, 0.55, 0.0), 0.98, 0.14, 0.06, segments=24)
    path = []
    for i in range(27):
        t = 3 * math.pi * i / 26
        r = 0.12 + 0.66 * t / (3 * math.pi)
        path.append((r * math.cos(t), r * math.sin(t)))
    plate(swirl, _ribbon(path, 0.14), (0.0, 0.545, 0.0), (0, 1, 0), (0, 0, -1), 0.05)
    # Three emitter posts on the rim with glowing caps.
    for k in range(3):
        a = math.radians(90 + 120 * k)
        x, z = 1.3 * math.cos(a), -1.3 * math.sin(a)
        cylinder(base, (x, 0.4, z), (x, 0.92, z), 0.11, segments=8)
        ellipsoid(tips, (x, 0.98, z), (0.15, 0.15, 0.15), rings=4, segments=8)
    # Light beam (a gentle frustum, 62 % transparent Neon) with three floating hoops + two sparkles.
    cylinder(beam, (0.0, 0.56, 0.0), (0.0, 2.85, 0.0), 0.76, segments=16, radius_b=0.6)
    for y, r in ((1.2, 1.02), (1.85, 0.95), (2.5, 0.88)):
        ring_tube(hoops, (0.0, y, 0.0), r, 0.12, 0.12, segments=16)
    star(sparkle, (0.22, 1.55, -0.2), 0.16, 0.05, normal=(0, 0, -1), inner_ratio=0.3)
    star(sparkle, (-0.28, 2.2, 0.15), 0.12, 0.04, normal=(0, 0, -1), inner_ratio=0.3)
    return m


# ================================================================================================
# 11. Shop_FastShoe
# ================================================================================================

# Shoe upper cross-sections, heel (+X) -> toe (-X): (x, top height, half width). Bottom = SOLE_TOP.
SHOE_SECTIONS = [
    (1.52, 1.15, 0.3),
    (1.42, 1.62, 0.5),
    (1.18, 1.9, 0.58),
    (0.8, 1.95, 0.6),
    (0.45, 1.75, 0.62),
    (0.1, 1.38, 0.62),
    (-0.35, 1.12, 0.62),
    (-0.85, 0.95, 0.6),
    (-1.25, 0.82, 0.52),
    (-1.5, 0.66, 0.36),
    (-1.62, 0.52, 0.16),
]
SOLE_TOP = 0.36


def _shoe_top(x: float) -> float:
    """Upper's top height at x (linear between SHOE_SECTIONS) — laces and the collar follow it."""
    for (x0, y0, _), (x1, y1, _) in zip(SHOE_SECTIONS, SHOE_SECTIONS[1:]):
        if x1 <= x <= x0:
            t = (x - x0) / (x1 - x0)
            return y0 + (y1 - y0) * t
    return SHOE_SECTIONS[-1][1]


def build_fast_shoe():
    """Chunky blue cartoon sneaker: white sole + toe cap + laces, yellow bolt, little white heel wings."""
    m = Model(
        "Shop_FastShoe",
        "ground centre of the sneaker's bounding box (sole at y = 0); toe points -X (the viewer's right "
        "from the front), lightning bolt on both sides; shop viewport prop for the Fast Walk pass; "
        "~3.8 long x 2.3 tall",
        budget=2000,
    )
    upper = m.piece("Upper", SHOE_BLUE, material="StudsSmall")
    white = m.piece("Trim", WHITE, material="StudsSmall")
    tread = m.piece("Tread", DEEP_BLUE, material="StudsSmall")
    opening = m.piece("Opening", SOFT_BLACK, material="Smooth")
    bolt = m.piece("Bolt", YELLOW, material="StudsSmall")

    # Sole: rounded-rectangle footprint (superellipse n = 3), white slab + navy tread + navy stripe.
    def footprint(scale: float) -> list:
        pts = []
        for i in range(20):
            t = 2 * math.pi * i / 20
            c, s_ = math.cos(t), math.sin(t)
            x = 1.68 * scale * math.copysign(abs(c) ** (2 / 3), c)
            z = 0.68 * scale * math.copysign(abs(s_) ** (2 / 3), s_)
            pts.append((x, z))
        return pts

    extrude_outline(white, footprint(1.0), 0.12, 0.46)
    extrude_outline(tread, footprint(0.98), 0.0, 0.14)
    extrude_outline(tread, footprint(1.012), 0.26, 0.32)
    # Upper: loft of superellipse cross-sections (boxy-round toy shoe), bottom buried in the sole.
    sections = []
    for x, top_y, w in SHOE_SECTIONS:
        cy, ry = (SOLE_TOP + top_y) / 2, (top_y - SOLE_TOP) / 2
        ring = []
        for k in range(12):
            phi = 2 * math.pi * k / 12
            c, s_ = math.cos(phi), math.sin(phi)
            ring.append((x, cy + ry * math.copysign(abs(s_) ** (2 / 3), s_), w * math.copysign(abs(c) ** (2 / 3), c)))
        sections.append(ring)
    loft(upper, sections)
    # Toe cap, tongue, padded collar ring around a dark ankle opening.
    ellipsoid(white, (-1.22, 0.62, 0.0), (0.48, 0.3, 0.55), rings=5, segments=12)
    oriented_ellipsoid(white, (0.38, 1.78, 0.0), (0.36, 0.42, 0.1), normal=(-0.8, 0.6, 0.0), up=(0, 1, 0), rings=5, segments=10)
    oriented_ellipsoid(opening, (0.95, 1.88, 0.0), (0.4, 0.42, 0.1), normal=(0, 1, 0), up=(1, 0, 0), rings=3, segments=12)
    collar = [(0.95 + 0.47 * math.cos(2 * math.pi * i / 14), 1.86, 0.45 * math.sin(2 * math.pi * i / 14)) for i in range(14)]
    tube(white, collar, 0.1, sides=6, closed=True)
    # Laces: three bars across the instep, bowed to follow the rounded top.
    for x in (0.15, -0.15, -0.45):
        y = _shoe_top(x) + 0.02
        tube(white, [(x, y - 0.12, -0.52), (x, y, 0.0), (x, y - 0.12, 0.52)], 0.075, sides=6)
    # Lightning bolt on both sides, tip trailing toward the heel (+X) on each face.
    zig = [(-0.12, 0.42), (0.2, 0.42), (0.04, 0.1), (0.22, 0.1), (-0.2, -0.46), (-0.06, -0.06), (-0.24, -0.06)]
    horizontal = [(y * 1.5, -x * 1.5) for x, y in zig]  # rotate -90 deg: the tip now points to -x
    for side in (-1, 1):
        # -Z plate: local +x = world -X (toe), so tip at local -x = heel. +Z plate: mirror x.
        outline = horizontal if side < 0 else [(-x, y) for x, y in horizontal]
        plate(bolt, outline, (0.2, 0.92, side * 0.62), (0, 0, side), (0, 1, 0), 0.14)
    # Heel wings: three scalloped feathers sweeping back and up, flared outward on each side.
    wing = [
        (0.0, -0.1),
        (0.05, 0.25),
        (0.2, 0.55),
        (0.42, 0.78),
        (0.7, 0.92),
        (1.08, 0.96),
        (0.72, 0.68),
        (1.14, 0.62),
        (0.74, 0.42),
        (1.08, 0.28),
        (0.76, 0.16),
        (0.5, 0.0),
        (0.2, -0.1),
    ]
    for side in (-1, 1):
        # normal (-0.35, 0, side): local +x (+Z face) / -x (-Z face) runs back (+X) and outward.
        outline = wing if side > 0 else [(-x, y) for x, y in wing]
        plate(white, outline, (1.15, 1.55, side * 0.55), (-0.35, 0.0, side), (0, 1, 0), 0.1)
    _recentre(m)
    return m


# ================================================================================================
# 12. Shop_AutoClicker
# ================================================================================================


def build_auto_clicker():
    """Yellow cartoon hand pointing up (click dashes at the fingertip) beside a big white cursor arrow."""
    m = Model(
        "Shop_AutoClicker",
        "ground centre of the bounding box (cuff + cursor tail at y = 0); front faces -Z: hand on the "
        "viewer's left, cursor arrow on the viewer's right pointing at it; shop viewport prop; ~2.6 wide x 3.3 tall",
        budget=2000,
    )
    skin = m.piece("Hand", HAND_YELLOW, material="StudsSmall")
    cuff = m.piece("Cuff", CUFF_BLUE, material="StudsSmall")
    white = m.piece("Cursor", WHITE, material="StudsSmall")  # cursor body + the cuff's white band
    rim = m.piece("CursorRim", SOFT_BLACK, material="Smooth")
    burst = m.piece("Burst", YELLOW, material="Smooth")

    hx = 0.45  # hand axis x (world +X = the viewer's left)
    # Sleeve cuff + white band, wrist, chunky palm.
    revolve(cuff, [(0.0, 0.0), (0.6, 0.0), (0.66, 0.06), (0.66, 0.5), (0.6, 0.56), (0.0, 0.56)], center=(hx, 0.0, 0.0), segments=16)
    ring_tube(white, (hx, 0.56, 0.0), 0.6, 0.16, 0.12, segments=16)
    cylinder(skin, (hx, 0.5, 0.0), (hx, 0.9, 0.0), 0.46, segments=12)
    ellipsoid(skin, (hx, 1.25, 0.02), (0.68, 0.6, 0.48), rings=6, segments=12)
    # Index finger straight up on the viewer's left (+X), three curled fingers as knuckle rolls on
    # top of the palm (their round ends face the viewer), thumb folded across the front.
    fx = hx + 0.3
    _capsule(skin, (fx, 1.45, -0.05), (fx, 2.62, -0.05), 0.22, segments=10)
    for k, x in enumerate((hx - 0.02, hx - 0.28, hx - 0.52)):
        r = 0.19 - 0.015 * k
        _capsule(skin, (x, 1.68 - 0.04 * k, -0.42), (x, 1.68 - 0.04 * k, 0.12), r, segments=8)
    _capsule(skin, (hx - 0.55, 1.02, -0.3), (hx + 0.1, 1.34, -0.5), 0.18, segments=8)
    # Fingernail glint (white) on the index tip front.
    oriented_ellipsoid(white, (fx, 2.6, -0.25), (0.1, 0.12, 0.03), normal=(0, 0, -1), rings=3, segments=8)
    # Click dashes around the fingertip (viewer-space angles; world x = -viewer x).
    tip = Vector((fx, 2.86, -0.05))
    for ang in (90.0, 30.0, 150.0):
        d = Vector((-math.cos(math.radians(ang)), math.sin(math.radians(ang)), 0.0))
        _capsule(burst, tuple(tip + d * 0.22), tuple(tip + d * 0.42), 0.07, segments=6, rings=1)
    # Cursor arrow: white plate over a slightly larger, thinner dark plate (outline on both faces).
    arrow = [(0.0, 0.0), (0.0, -1.0), (0.24, -0.77), (0.42, -1.18), (0.6, -1.1), (0.42, -0.71), (0.74, -0.7)]
    arrow = [(x * 1.25, y * 1.25) for x, y in arrow]
    origin = (hx - 0.9, 1.56, -0.45)  # arrow tip just right of the palm (viewer), in front of it
    plate(white, arrow, origin, (0, 0, -1), (0, 1, 0), 0.26)
    plate(rim, _offset_outline(arrow, 0.09), origin, (0, 0, -1), (0, 1, 0), 0.16)
    _recentre(m)
    return m


# ================================================================================================
# 13. Shop_OfflineMoon
# ================================================================================================


def build_offline_moon():
    """Puffy sleeping crescent moon (closed eyes, blush, 'o' snore) with craters and a floating 'Zzz'."""
    m = Model(
        "Shop_OfflineMoon",
        "ground centre of the bounding box (crescent's lowest curve at y = 0); face + Zzz on -Z, craters "
        "front and back; shop viewport prop for offline earnings; ~2.7 wide x 2.9 tall",
        budget=2000,
    )
    moon = m.piece("Moon", MOON_YELLOW, material="StudsSmall")
    craters = m.piece("Craters", MOON_CRATER, material="StudsSmall")
    face = m.piece("Face", SOFT_BLACK, material="Smooth")
    blush = m.piece("Blush", BLUSH, material="Smooth")
    zzz = m.piece("Zzz", ZZZ_PURPLE, material="StudsSmall")

    # Crescent: loft along an arc (radius 1.0 about c) from viewer-angle -160 to 70 deg, so the convex
    # side faces the lower right and the horns open to the upper left. Cross-sections are ellipses
    # (in-plane half width w, Z half depth dz) that swell mid-arc and taper to rounded tips.
    c = Vector((0.0, 1.5, 0.0))
    spine, a0, a1, half_w, half_d = 1.0, -160.0, 70.0, 0.58, 0.45

    def size_at(t: float) -> tuple:
        swell = math.sin(math.pi * t) ** 0.75
        return 0.05 + (half_w - 0.05) * swell, 0.05 + (half_d - 0.05) * swell

    def radial(ang_deg: float) -> Vector:
        a = math.radians(ang_deg)
        return Vector((-math.cos(a), math.sin(a), 0.0))  # viewer-space angle -> world (x flipped)

    sections = []
    steps, sides = 24, 14
    for i in range(steps + 1):
        t = i / steps
        w, dz = size_at(t)
        r = radial(a0 + (a1 - a0) * t)
        p = c + r * spine
        sections.append([tuple(p + r * (w * math.cos(2 * math.pi * k / sides)) + Vector((0, 0, dz * math.sin(2 * math.pi * k / sides)))) for k in range(sides)])
    loft(moon, sections)

    def surface(vx: float, vy: float, side: float) -> Vector:
        """World point on the crescent's -Z (side -1) / +Z (side +1) skin at viewer offset (vx, vy) from c."""
        ang = math.degrees(math.atan2(vy, vx))
        t = min(max((ang - a0) / (a1 - a0), 0.0), 1.0)
        w, dz = size_at(t)
        d = math.hypot(vx, vy) - spine
        z = dz * math.sqrt(max(0.0, 1.0 - (d / w) ** 2))
        return Vector((c.x - vx, c.y + vy, side * z))

    # Sleepy face on the fat lower-right part: closed-eye arcs, blush, small round snoring mouth.
    fc = (0.72, -0.62)  # viewer offset of the face centre from c
    for ex in (-0.2, 0.2):
        p = surface(fc[0] + ex, fc[1] + 0.1, -1)
        plate(face, _ribbon(_arc(0.0, 0.06, 0.12, 0.08, 200, 340, 6), 0.05), (p.x, p.y, p.z + 0.01), (0, 0, -1), (0, 1, 0), 0.08)
        q = surface(fc[0] + ex * 1.55, fc[1] - 0.07, -1)
        oriented_ellipsoid(blush, (q.x, q.y, q.z + 0.015), (0.1, 0.06, 0.03), normal=(0, 0, -1), rings=3, segments=8)
    p = surface(fc[0], fc[1] - 0.2, -1)
    oriented_ellipsoid(face, (p.x, p.y, p.z + 0.01), (0.06, 0.08, 0.03), normal=(0, 0, -1), rings=3, segments=8)
    # Craters: two on the front near the horns, three on the back.
    for vx, vy, side, r in ((-0.85, -0.45, -1, 0.17), (0.66, 0.6, -1, 0.15), (0.7, -0.6, 1, 0.24), (-0.8, -0.5, 1, 0.18), (0.8, 0.3, 1, 0.17)):
        p = surface(vx, vy, side)
        oriented_ellipsoid(craters, (p.x, p.y, p.z), (r, r, 0.04), normal=(0, 0, side), rings=3, segments=10)
    # "Zzz" drifting up-left out of the crescent's opening, growing as it rises.
    for (vx, vy), h in (((-0.1, 0.18), 0.34), ((-0.52, 0.62), 0.44), ((-1.0, 1.12), 0.54)):
        plate(zzz, _letter_z(h), (c.x - vx, c.y + vy, -0.05), (0, 0, -1), (0.12, 1, 0), 0.14)
    _recentre(m)
    return m


# ================================================================================================
# 14. Shop_PetSlots
# ================================================================================================


def build_pet_slots():
    """Pink-rimmed pet tag on its edge with a brown paw print on both faces and a big green '+'."""
    radius, thick = 1.3, 0.46
    cy = radius
    m = Model(
        "Shop_PetSlots",
        f"ground point under the tag (rim touches y = 0); tag centre y = {cy:.2f}; paw on -Z and +Z, "
        "'+' badge at the viewer's upper right (front); shop viewport prop for Pet Slots; spin about +Y",
        budget=2000,
    )
    rim = m.piece("Rim", TAG_RIM, material="StudsSmall")
    face = m.piece("Face", TAG_FACE, material="StudsSmall")
    paw = m.piece("Paw", PAW_BROWN, material="StudsSmall")
    plus = m.piece("Plus", PLUS_GREEN, material="StudsSmall")
    border = m.piece("PlusBorder", WHITE, material="StudsSmall")

    c = Vector((0.0, cy, 0.0))
    face_r = radius * 0.82
    b = 0.08
    revolve(
        rim,
        [
            (face_r - 0.04, -thick / 2),
            (radius - b, -thick / 2),
            (radius, -thick / 2 + b),
            (radius, thick / 2 - b),
            (radius - b, thick / 2),
            (face_r - 0.04, thick / 2),
        ],
        center=tuple(c),
        segments=28,
        closed=True,
        rot=rot_x(90),
    )
    face_t = thick * 0.7
    revolve(face, [(0.0, -face_t / 2), (face_r, -face_t / 2), (face_r, face_t / 2), (0.0, face_t / 2)], center=tuple(c), segments=28, rot=rot_x(90))
    # Paw print on both faces: a wide main pad (narrower on top) and four tilted toe beans.
    for side in (-1, 1):
        z = side * face_t / 2

        def taper(x, y, zz):
            return (x * (1.0 - 0.22 * y / 0.38), y, zz)

        ellipsoid(paw, (0.0, cy - 0.28, z), (0.5, 0.38, 0.11), rings=6, segments=12, deform=taper)
        for bx, by, tilt in ((0.54, 0.1, 30.0), (0.2, 0.4, 10.0), (-0.2, 0.4, -10.0), (-0.54, 0.1, -30.0)):
            up = (-math.sin(math.radians(tilt)), math.cos(math.radians(tilt)), 0.0)
            oriented_ellipsoid(paw, (bx, cy + by, z), (0.17, 0.23, 0.1), normal=(0, 0, side), up=up, rings=4, segments=10)
    # "+" badge at the viewer's upper right: green cross over a thinner, larger white border.
    px, py = -0.78, cy + 0.78
    for piece, arm, width, depth in ((plus, 0.96, 0.36, 0.7), (border, 1.14, 0.54, 0.54)):
        block(piece, (px, py, 0.0), (width, arm, depth), bevel=0.1)
        block(piece, (px, py, 0.0), (arm, width, depth), bevel=0.1)
    return m


# ================================================================================================
# 15. Shop_TripleEgg
# ================================================================================================


def _egg_profile(height: float, radius: float, rings_bottom: int = 4, rings_top: int = 5) -> tuple:
    """
    Revolve profile of a cartoon egg (rounder bottom half, taller pointier top half) standing on
    y = 0, plus hb = the height of its widest ring. Returns (profile, hb).
    """
    hb = height * 0.42
    profile = [(0.0, 0.0)]
    for i in range(1, rings_bottom + 1):
        a = -math.pi / 2 + (math.pi / 2) * i / rings_bottom
        profile.append((radius * math.cos(a), hb + hb * math.sin(a)))
    for i in range(1, rings_top):
        a = (math.pi / 2) * i / rings_top
        profile.append((radius * math.cos(a), hb + (height - hb) * math.sin(a)))
    profile.append((0.0, height))
    return profile, hb


def _egg(shell, spots, base, height: float, radius: float, rot, spot_list: list):
    """
    One spotted egg standing on `base`, tilted by `rot` about its bottom pole. spot_list =
    [(yaw deg, elevation deg, size)]: yaw 0 = front (-Z), 90 = +X; elevation -90 (bottom) .. 90 (top),
    measured on the egg's own half-ellipses, so spots hug the shell at any tilt.
    """
    profile, hb = _egg_profile(height, radius)
    revolve(shell, profile, center=tuple(base), segments=14, rot=rot)
    b = Vector(base)
    for yaw, elev, size in spot_list:
        e, y_r = math.radians(elev), math.radians(yaw)
        half = hb if elev < 0 else height - hb
        horizontal = Vector((math.sin(y_r), 0.0, -math.cos(y_r)))
        local = horizontal * (radius * math.cos(e)) + Vector((0, hb + half * math.sin(e), 0))
        grad = Vector((local.x / radius**2, (local.y - hb) / half**2, local.z / radius**2)).normalized()
        p = b + rot @ local
        n = rot @ grad
        oriented_ellipsoid(spots, tuple(p - n * 0.02), (size, size * 0.9, 0.07), normal=tuple(n), up=tuple(rot @ Vector((0, 1, 0))), rings=3, segments=10)


def build_triple_egg():
    """Three candy eggs (pink, mint, blue) with yellow spots, in a sunny straw nest."""
    m = Model(
        "Shop_TripleEgg",
        "ground centre under the nest (y = 0); big egg at the back, two small eggs lean out front-left / "
        "front-right; shop viewport prop for Triple Hatch; ~3.4 wide x 2.5 tall",
        budget=2000,
    )
    pink = m.piece("ShellPink", EGG_PINK, material="StudsSmall")
    blue = m.piece("ShellBlue", EGG_BLUE, material="StudsSmall")
    mint = m.piece("ShellMint", EGG_MINT, material="StudsSmall")
    spots = m.piece("Spots", SPOT_YELLOW, material="StudsSmall")
    straw = m.piece("Straw", STRAW, material="StudsSmall")
    nest = m.piece("NestBowl", STRAW_DARK, material="StudsSmall")

    # Nest: a shallow dark bowl + a lumpy straw ring + a few straw ends poking out.
    ellipsoid(nest, (0.0, 0.18, 0.0), (1.45, 0.18, 1.05), rings=4, segments=14, deform=lambda x, y, z: (x, max(y, -0.18), z))
    ring_pts, ring_r = [], []
    for i in range(20):
        t = 2 * math.pi * i / 20
        # Centre 0.29 - max radius 0.26 - wobble 0.03 = 0: the lumpy ring just touches the ground.
        ring_pts.append((1.5 * math.cos(t), 0.29 + 0.03 * math.sin(3 * t), 1.12 * math.sin(t)))
        ring_r.append(0.22 + 0.04 * math.sin(5 * t))
    tube(straw, ring_pts, 0.22, sides=6, closed=True, radii=ring_r)
    for k in range(6):
        t = 2 * math.pi * (k + 0.3) / 6
        p = Vector((1.5 * math.cos(t), 0.3, 1.12 * math.sin(t)))
        out = Vector((math.cos(t), 0.5, math.sin(t))).normalized()
        _capsule(straw, tuple(p), tuple(p + out * 0.45), 0.05, segments=6, rings=1)
    # Eggs: big one at the back, two smaller ones leaning outward and a little toward the viewer.
    big = [(-20, 10, 0.26), (35, 45, 0.2), (160, 20, 0.28), (230, 55, 0.2), (100, -15, 0.22), (290, 5, 0.24)]
    small = [(-10, 20, 0.2), (60, 50, 0.15), (140, 0, 0.2), (220, 35, 0.17), (300, -10, 0.18)]
    _egg(pink, spots, (0.0, 0.1, 0.32), 2.35, 0.9, rot_x(4), big)
    _egg(mint, spots, (0.92, 0.1, -0.22), 1.7, 0.66, rot_z(-14) @ rot_x(-8), small)
    _egg(blue, spots, (-0.9, 0.1, -0.28), 1.6, 0.62, rot_z(14) @ rot_x(-8), [(y + 40, e, s) for y, e, s in small])
    return m


BUILDERS = {
    "Shop_CashStack": build_cash_stack,
    "Shop_GemCluster": build_gem_cluster,
    "Shop_SpinToken": build_spin_token,
    "Shop_BoostPotion": build_boost_potion,
    "Shop_MoneyBag": build_money_bag,
    "Shop_VipCrown": build_vip_crown,
    "Shop_ServerBoost": build_server_boost,
    "Shop_CashPile": build_cash_pile,
    "Shop_GemChest": build_gem_chest,
    "Shop_Teleporter": build_teleporter,
    "Shop_FastShoe": build_fast_shoe,
    "Shop_AutoClicker": build_auto_clicker,
    "Shop_OfflineMoon": build_offline_moon,
    "Shop_PetSlots": build_pet_slots,
    "Shop_TripleEgg": build_triple_egg,
}
