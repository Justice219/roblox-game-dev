"""
event_harvest.py — "Harvest Feast" Thanksgiving event decor (spec §10, 2026-11-01 -> 2026-12-01 UTC).

Everything here is spawned into the hub's EVENT group (HubLayout.event.harvest), which the event
service shows while the event runs and destroys cleanly after it ends. Kid-friendly autumn fair:
hay bales, pumpkins, a giant cornucopia, string lights, autumn trees, a cute pilgrim-hat Turkey
statue and a pie stand, framed by a hay-bale entrance arch.

Models (pivot = ground centre, front = -Z unless stated):
    Harvest_HayBale       4.6 x 2.6 x 2.8 bale with twine bands (stackable: top y = 2.6)
    Harvest_Pumpkin       ribbed pumpkin (3.6 wide); `Body` TINTED (orange / cream / gold)
    Harvest_Cornucopia    giant wicker horn (~26 long, ~19 tall) curling up at the back (+Z),
                          mouth faces -Z with pumpkins, apples, corn and grapes spilling out
    Harvest_StringLights  two wooden poles at x = +-20 with a sagging wire of warm/orange bulbs
    Harvest_AutumnTree    round autumn tree; `Leaves` TINTED (orange / red / gold)
    Harvest_TurkeyStatue  cartoon turkey in a pilgrim hat on a round pedestal (faces -Z)
    Harvest_PieStand      market stall with an orange/cream awning and pies; `Sign` on top
    Harvest_Arch          hay-bale pillars + "HARVEST FEAST" board (`Sign` front face) with an
                          autumn leaf garland; walkway |x| <= 6.6
  Plot decorations (bought with Acorns, placed at HubLayout.plotDecor slots by the event service):
    Harvest_CornucopiaSmall  the cornucopia at 0.32 scale (~10 long)
    Harvest_CornucopiaMini   the cornucopia at 0.16 scale (~2 x 3 x 4, plot lawn decoration)
    Harvest_PumpkinPile      small hay bale + heap of orange / cream pumpkins
    Harvest_Scarecrow        friendly scarecrow (~6.6 wide arms, ~9.6 tall) with a pumpkin buddy
    Harvest_Garland          leafy garland + warm bulbs across the plot road on two curb poles;
                             pivot = ground at the road centre, swag at y ~ 12.5

Budgets: props <= 1,500, stalls/statues/arch <= 3,500, cornucopia (event hero) <= 5,000.
"""

import math

from mathutils import Vector

from snkit.core import (
    BROWN,
    CHARCOAL,
    CREAM,
    LAMP_WARM,
    LEAF,
    Model,
    ORANGE,
    PURPLE,
    TOY_RED,
    WOOD,
    WOOD_DARK,
    YELLOW,
)
from snkit.kit import block, sign_frame
from snkit.shapes import bar, cylinder, ellipsoid, loft

from models.hub import STONE, bulb, lin, ring, stall

HAY = (236, 200, 100)
TWINE = (150, 96, 52)
TURKEY = (150, 92, 52)
STEM = (96, 140, 52)
CRUST = (222, 168, 100)
AUTUMN = (240, 130, 40)


def _lobed(k=10, depth=0.08):
    """Ellipsoid deform that adds k vertical ribs (pumpkin lobes)."""

    def deform(x, y, z):
        a = math.atan2(z, x)
        s = 1.0 + depth * math.cos(k * a)
        return (x * s, y, z * s)

    return deform


def _spin_z(angle):
    """Ellipsoid deform rotating local XY by `angle` radians about Z (fanned tail feathers)."""
    c, s = math.cos(angle), math.sin(angle)

    def deform(x, y, z):
        return (x * c - y * s, x * s + y * c, z)

    return deform


def pumpkin(body, stem, center, r=1.7, h=1.25, rings=8, segments=20):
    """Ribbed pumpkin sitting on `center` (bottom centre)."""
    cx, cy, cz = center
    ellipsoid(body, (cx, cy + h, cz), (r, h, r), rings=rings, segments=segments, deform=_lobed())
    cylinder(stem, (cx, cy + h * 1.85, cz), (cx + 0.15 * r, cy + h * 2.35, cz), 0.13 * r, segments=6, radius_b=0.09 * r)


def build_hay_bale():
    """Rounded hay bale with two twine bands."""
    m = Model("Harvest_HayBale", "ground centre; 4.6 x 2.6 x 2.8, top y = 2.6 (stackable)", budget=600)
    hay = m.piece("Hay", HAY)
    twine = m.piece("Twine", TWINE)
    block(hay, (0.0, 1.3, 0.0), (4.6, 2.6, 2.8), bevel=0.45, segments=2)
    for x in (-1.2, 1.2):
        block(twine, (x, 1.3, 0.0), (0.3, 2.68, 2.88), bevel=0.1)
    return m


def build_pumpkin():
    """Single ribbed pumpkin (tinted body)."""
    m = Model("Harvest_Pumpkin", "ground centre; ~3.6 wide, ~3 tall; Body tinted", budget=600)
    body = m.piece("Body", ORANGE, tinted=True)
    stem = m.piece("Stem", STEM)
    pumpkin(body, stem, (0.0, 0.0, 0.0))
    block(stem, (0.45, 2.55, 0.25), (0.9, 0.1, 0.5), bevel=0.03)
    return m


def _cornucopia(key, pivot, budget, s, segs=16):
    """
    Wicker horn curling up at the back with produce spilling out of the mouth (-Z), scaled by s
    (s = 1 is the ~30-long event-square centrepiece; the plot decoration uses s = 0.32).
    """
    m = Model(key, pivot, budget=budget)
    wicker = m.piece("Wicker", WOOD)
    bands = m.piece("Bands", WOOD_DARK)
    pk = m.piece("Pumpkin", ORANGE)
    apple = m.piece("Apple", TOY_RED)
    corn = m.piece("Corn", YELLOW)
    grape = m.piece("Grape", PURPLE)
    leaves = m.piece("Leaves", LEAF)

    def v(x, y, z):
        return (x * s, y * s, z * s)

    # Spine: starts at the mouth heading +Z, curls up and back (tangent angle 0 -> 215 deg).
    samples = 64
    ds = 30.0 * s / samples
    p = Vector(v(0.0, 5.3, -8.0))
    spine = []
    for i in range(samples + 1):
        t = i / samples
        theta = math.radians(215.0) * t**2.3
        tangent = Vector((0.0, math.sin(theta), math.cos(theta)))
        spine.append((p.copy(), tangent, (5.0 * (1.0 - t) ** 1.2 + 0.3) * s))
        p = p + tangent * ds

    def section(index, grow=0.0):
        centre, tangent, radius = spine[index]
        side = Vector((1.0, 0.0, 0.0))
        up = side.cross(tangent).normalized()
        pts = []
        for k in range(segs):
            a = 2 * math.pi * k / segs
            q = centre + (side * math.cos(a) + up * math.sin(a)) * (radius + grow * s)
            pts.append((q.x, q.y, q.z))
        return pts

    loft(wicker, [section(i) for i in range(0, samples + 1, 4)])
    # Woven bands (slightly proud rings) and a thick mouth rim: open tubes (no end caps), so the rim
    # never puts a cap on the wicker's mouth cap plane (z-fight rule, docs/areas-art.md).
    for i in (8, 16, 24, 32, 40, 48):
        loft(bands, [section(i - 1, 0.22), section(i + 1, 0.22)], cap_start=False, cap_end=False)
    loft(bands, [section(0, 0.45), section(2, 0.45)], cap_start=False, cap_end=False)
    # Produce spilling out of the mouth onto the ground in front (tiny copies get fewer facets).
    tiny = s < 0.25
    pk_segments = 14 if s > 0.5 else (8 if tiny else 10)
    for c, r in (((-2.6, 0.0, -10.0), 1.6), ((2.9, 0.0, -11.2), 1.3), ((0.4, 2.2, -8.6), 1.5)):
        pumpkin(pk, leaves, v(*c), r=r * s, h=r * 0.75 * s, rings=5 if tiny else 6, segments=pk_segments)
    for c in ((-0.8, 0.9, -12.3), (1.2, 0.9, -12.9), (-3.9, 0.9, -12.2), (3.0, 3.1, -8.1), (-2.2, 3.4, -8.0)):
        ellipsoid(apple, v(*c), v(0.9, 0.85, 0.9), rings=4 if tiny else 5, segments=6 if tiny else 8)
    for (x, y, z), lean in (((-1.8, 1.0, -13.8), 0.6), ((4.6, 0.8, -9.6), -0.8), ((-0.6, 4.6, -8.4), 0.3)):
        a = v(x - 1.8 * math.sin(lean), y, z - 1.8 * math.cos(lean))
        b = v(x + 1.8 * math.sin(lean), y + 0.3, z + 1.8 * math.cos(lean))
        cylinder(corn, a, b, 0.65 * s, segments=8, radius_b=0.45 * s)
        husk_end = (b[0] * 0.7 + a[0] * 0.3, b[1], b[2] * 0.7 + a[2] * 0.3)
        cylinder(leaves, (a[0], a[1] - 0.15 * s, a[2]), husk_end, 0.72 * s, segments=6, radius_b=0.2 * s)
    for gx, gz in ((2.2, -6.8), (-3.4, -6.9)):
        for i in range(3 if tiny else 6):
            ox, oz = 0.55 * math.cos(i * 1.05), 0.55 * math.sin(i * 1.05)
            ellipsoid(grape, v(gx + ox, 4.4 - 0.45 * (i % 3), gz + oz), v(0.5, 0.5, 0.5), rings=4, segments=6)
    return m


def build_cornucopia():
    """Giant event-square cornucopia (~30 long, ~19 tall)."""
    return _cornucopia("Harvest_Cornucopia", "ground centre; mouth faces -Z at z ~ -8; ~26 long, ~19 tall", 5000, 1.0)


def build_cornucopia_small():
    """Plot-decoration cornucopia (~10 long, ~6 tall)."""
    return _cornucopia("Harvest_CornucopiaSmall", "ground centre; mouth faces -Z; ~10 long, ~6 tall", 2500, 0.32, segs=12)


def build_cornucopia_mini():
    """Plot-lawn cornucopia (~2 wide x 3 tall x 4 long): the same horn at 0.16 scale, fewer sides."""
    return _cornucopia("Harvest_CornucopiaMini", "ground centre; mouth faces -Z; ~2 x 3 x 4", 1600, 0.16, segs=8)


def build_pumpkin_pile():
    """Plot decoration: a little hay bale with a heap of orange / cream / gold pumpkins."""
    m = Model("Harvest_PumpkinPile", "ground centre; ~7 x 5 footprint, top y ~ 4.6", budget=1500)
    hay = m.piece("Hay", HAY)
    twine = m.piece("Twine", TWINE)
    orange = m.piece("PumpkinOrange", ORANGE)
    cream = m.piece("PumpkinCream", CREAM)
    stem = m.piece("Stem", STEM)
    block(hay, (1.2, 0.9, 0.6), (3.6, 1.8, 2.4), bevel=0.35, segments=2)
    for x in (0.3, 2.1):
        block(twine, (x, 0.9, 0.6), (0.25, 1.86, 2.46), bevel=0.08)
    pumpkin(orange, stem, (1.2, 1.8, 0.6), r=1.25, h=0.95, rings=6, segments=14)
    pumpkin(orange, stem, (-2.0, 0.0, -0.4), r=1.6, h=1.2, rings=6, segments=14)
    pumpkin(cream, stem, (-0.6, 0.0, -1.9), r=1.1, h=0.85, rings=6, segments=12)
    pumpkin(cream, stem, (3.1, 0.0, -1.0), r=0.9, h=0.7, rings=6, segments=12)
    return m


def build_scarecrow():
    """Plot decoration: friendly scarecrow (straw hat, patched shirt, pumpkin buddy at its feet)."""
    m = Model("Harvest_Scarecrow", "ground centre; faces -Z; ~5 wide arms, hat top y ~ 9.6", budget=1800)
    post = m.piece("Post", WOOD_DARK)
    hay = m.piece("Straw", HAY)
    shirt = m.piece("Shirt", TOY_RED)
    patch = m.piece("Patch", CREAM)
    face = m.piece("Face", CHARCOAL)
    pk = m.piece("Pumpkin", ORANGE)
    stem = m.piece("Stem", STEM)
    block(post, (0.0, 0.25, 0.0), (1.8, 0.5, 1.8), bevel=0.12)
    bar(post, (0.0, 0.5, 0.0), (0.0, 7.0, 0.0), 0.45)
    bar(post, (-2.6, 5.4, 0.0), (2.6, 5.4, 0.0), 0.35)
    block(shirt, (0.0, 4.6, 0.0), (2.4, 2.6, 1.3), bevel=0.25)
    for s_ in (-1, 1):
        block(shirt, (s_ * 1.8, 5.4, 0.0), (1.4, 0.9, 0.9), bevel=0.15)
        ellipsoid(hay, (s_ * 2.85, 5.4, 0.0), (0.45, 0.4, 0.4), rings=4, segments=6)
    block(patch, (0.6, 4.9, -0.67), (0.7, 0.7, 0.08), bevel=0.03)
    block(hay, (0.0, 3.1, 0.0), (2.0, 0.6, 1.1), bevel=0.15)
    ellipsoid(hay, (0.0, 7.1, 0.0), (1.05, 1.1, 1.0), rings=6, segments=10)
    for s_ in (-1, 1):
        ellipsoid(face, (s_ * 0.38, 7.3, -0.95), (0.16, 0.18, 0.08), rings=3, segments=6)
    block(face, (0.0, 6.75, -0.98), (0.6, 0.12, 0.06), bevel=0.02)
    ring(hay, 0.0, 1.8, 7.95, 8.15, 14, chamfer=0.05)
    cylinder(hay, (0.0, 8.1, 0.0), (0.0, 9.3, 0.0), 0.95, segments=12, radius_b=0.7)
    cylinder(shirt, (0.0, 8.15, 0.0), (0.0, 8.5, 0.0), 0.98, segments=12)
    pumpkin(pk, stem, (1.6, 0.0, -1.2), r=0.9, h=0.7, rings=6, segments=12)
    return m


def build_garland():
    """
    Plot decoration: leafy autumn garland with warm bulbs and mini pumpkins strung across the
    plot road just past the entrance arch. Pivot = ground at the road centre; two slim poles stand
    on the road curbs (x = +-9.6), the swag hangs at y ~ 12.5 (sags from 13.4 to 11.9). No collision.
    """
    m = Model("Harvest_Garland", "ground at the road centre; poles at x = +-9.6; swag hangs at y ~ 12.5; faces -Z", budget=2000)
    poles = m.piece("Poles", WOOD_DARK)
    rope = m.piece("Rope", TWINE)
    leaf_o = m.piece("LeafOrange", ORANGE)
    leaf_r = m.piece("LeafRed", TOY_RED)
    leaf_y = m.piece("LeafYellow", YELLOW)
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    for x in (-9.6, 9.6):
        block(poles, (x, 0.65, 0.0), (0.9, 0.5, 0.9), bevel=0.08)
        block(poles, (x, 7.1, 0.0), (0.45, 13.0, 0.45), bevel=0.06)
        block(poles, (x, 13.7, 0.0), (0.7, 0.25, 0.7), bevel=0.05)

    def y_at(x):
        return 13.4 - 1.5 * (1.0 - (x / 9.6) ** 2)

    xs = lin(-9.6, 9.6, 12)
    for a, b in zip(xs, xs[1:]):
        bar(rope, (a, y_at(a), 0.0), (b, y_at(b), 0.0), 0.14)
    pieces = (leaf_o, leaf_r, leaf_y)
    for i, x in enumerate(lin(-8.6, 8.6, 15)):
        block(pieces[i % 3], (x, y_at(x) - 0.3, -0.12), (0.8, 0.6, 0.18), bevel=0.06)
    for x in lin(-8.0, 8.0, 7):
        bulb(bulbs, (x + 0.55, y_at(x + 0.55) - 0.75, 0.0), radius=0.3)
    for x in (-5.0, 5.0):
        pumpkin(leaf_o, rope, (x, y_at(x) - 1.55, -0.15), r=0.5, h=0.38, rings=5, segments=10)
    return m


def build_string_lights():
    """Two poles 40 apart with a sagging wire of alternating warm / orange bulbs."""
    m = Model("Harvest_StringLights", "ground centre; poles at x = +-20, wire at y ~ 11.8 sagging to ~9.2", budget=1500)
    poles = m.piece("Poles", WOOD_DARK)
    wire = m.piece("Wire", CHARCOAL)
    warm = m.piece("BulbsWarm", LAMP_WARM, material="Neon")
    orange = m.piece("BulbsOrange", ORANGE, material="Neon")
    for x in (-20.0, 20.0):
        block(poles, (x, 0.4, 0.0), (1.8, 0.8, 1.8), bevel=0.15)
        block(poles, (x, 6.4, 0.0), (0.7, 12.8, 0.7), bevel=0.1)
        block(poles, (x, 12.95, 0.0), (1.0, 0.3, 1.0), bevel=0.08)

    def y_at(x):
        return 11.8 - 2.6 * (1.0 - (x / 20.0) ** 2)

    xs = lin(-20.0, 20.0, 16)
    for a, b in zip(xs, xs[1:]):
        bar(wire, (a, y_at(a), 0.0), (b, y_at(b), 0.0), 0.12)
    for i, x in enumerate(lin(-17.5, 17.5, 14)):
        y = y_at(x)
        bar(wire, (x, y, 0.0), (x, y - 0.4, 0.0), 0.1)
        bulb(warm if i % 2 == 0 else orange, (x, y - 0.75, 0.0), radius=0.38)
    return m


def build_autumn_tree():
    """Round autumn tree with tinted leaves and a few fallen leaves on the ground."""
    m = Model("Harvest_AutumnTree", "ground centre; canopy radius ~5, top y ~ 14; Leaves tinted", budget=900)
    trunk = m.piece("Trunk", BROWN)
    leaves = m.piece("Leaves", AUTUMN, tinted=True)
    cylinder(trunk, (0.0, 0.0, 0.0), (0.0, 7.5, 0.0), 0.8, segments=8, radius_b=0.6)
    bar(trunk, (0.0, 6.0, 0.0), (1.8, 8.4, 0.6), 0.5)
    ellipsoid(leaves, (0.0, 10.0, 0.0), (4.8, 3.8, 4.8), rings=6, segments=10)
    ellipsoid(leaves, (-2.4, 8.3, 1.4), (2.8, 2.4, 2.8), rings=5, segments=8)
    ellipsoid(leaves, (2.5, 8.6, -1.2), (3.0, 2.5, 3.0), rings=5, segments=8)
    ellipsoid(leaves, (0.6, 12.6, -0.4), (2.6, 1.8, 2.6), rings=5, segments=8)
    for x, z in ((3.6, 2.4), (-3.0, -2.8), (1.0, -4.2), (-4.4, 1.0)):
        block(leaves, (x, 0.06, z), (0.9, 0.12, 0.6), bevel=0.03)
    return m


def build_turkey_statue():
    """Cute cartoon turkey in a pilgrim hat on a round pedestal (the Harvest Feast mascot)."""
    m = Model("Harvest_TurkeyStatue", "ground centre; faces -Z; pedestal top y = 1.9; hat top y ~ 11.8", budget=3500)
    ped = m.piece("Pedestal", STONE)
    gold = m.piece("Gold", YELLOW)
    body = m.piece("Body", TURKEY)
    feather_o = m.piece("FeatherOrange", ORANGE)
    feather_r = m.piece("FeatherRed", TOY_RED)
    dark = m.piece("Dark", CHARCOAL)
    ring(ped, 0.0, 4.2, 0.0, 1.6, 24, chamfer=0.2)
    ring(gold, 0.0, 4.45, 1.6, 1.9, 24, chamfer=0.1)
    # Tail fan (behind, +Z): outer row orange/red, inner row gold.
    for i, a in enumerate(lin(-1.35, 1.35, 6)):
        piece = feather_o if i % 2 == 0 else feather_r
        cx, cy = 3.7 * math.sin(a), 6.0 + 3.7 * math.cos(a)
        ellipsoid(piece, (cx, cy, 2.6), (1.15, 3.6, 0.35), rings=5, segments=8, deform=_spin_z(-a))
    for a in lin(-1.0, 1.0, 4):
        cx, cy = 2.5 * math.sin(a), 6.0 + 2.5 * math.cos(a)
        ellipsoid(gold, (cx, cy, 2.1), (0.85, 2.4, 0.3), rings=5, segments=8, deform=_spin_z(-a))
    # Body, wings, neck, head.
    ellipsoid(body, (0.0, 5.1, 0.3), (2.6, 2.6, 3.0), rings=8, segments=12)
    for s in (-1, 1):
        ellipsoid(body, (s * 2.4, 5.2, 0.5), (0.7, 1.8, 2.2), rings=5, segments=8)
    cylinder(body, (0.0, 6.2, -1.2), (0.0, 8.1, -1.8), 0.95, segments=10)
    ellipsoid(body, (0.0, 8.7, -1.9), (1.35, 1.4, 1.3), rings=6, segments=10)
    # Face: beak, wattle, eyes.
    cylinder(gold, (0.0, 8.55, -3.0), (0.0, 8.35, -3.9), 0.42, segments=8, radius_b=0.06)
    ellipsoid(feather_r, (0.3, 7.85, -3.0), (0.35, 0.75, 0.3), rings=4, segments=6)
    for s in (-1, 1):
        ellipsoid(ped, (s * 0.55, 9.05, -2.95), (0.4, 0.45, 0.25), rings=4, segments=8)
        ellipsoid(dark, (s * 0.55, 9.05, -3.18), (0.2, 0.24, 0.1), rings=3, segments=6)
    # Pilgrim hat with a gold buckle.
    ring(dark, 0.0, 1.7, 9.85, 10.1, 14, chamfer=0.05, center=(0.0, -1.9))
    cylinder(dark, (0.0, 10.05, -1.9), (0.0, 11.85, -1.9), 1.0, segments=12, radius_b=0.85)
    block(gold, (0.0, 10.55, -2.85), (0.95, 0.75, 0.14), bevel=0.04)
    # Legs + feet.
    for s in (-1, 1):
        cylinder(feather_o, (s * 0.9, 1.9, 0.2), (s * 0.9, 3.0, 0.2), 0.3, segments=6)
        block(feather_o, (s * 0.9, 2.0, -0.2), (0.9, 0.2, 1.3), bevel=0.05)
    return m


def build_pie_stand():
    """Harvest pie stall: orange/cream awning, three pies on the counter, pie tower behind."""
    m = Model("Harvest_PieStand", "ground centre, front -Z; Sign front at z = -4.46; counter top y = 3.7", budget=3500)
    wood = m.piece("Wood", WOOD)
    wood_dark = m.piece("WoodDark", WOOD_DARK)
    awning_a = m.piece("AwningA", ORANGE)
    awning_b = m.piece("AwningB", CREAM)
    frame = m.piece("Frame", CHARCOAL)
    sign = m.piece("Sign", CREAM)
    crust = m.piece("Crust", CRUST)
    top = stall(m, wood, wood_dark, awning_a, awning_b, frame, sign)

    def pie(x, y, z, r=1.3):
        ring(crust, 0.0, r, y, y + 0.45, 16, chamfer=0.12, center=(x, z))
        ring(awning_a, 0.0, r - 0.2, y + 0.3, y + 0.5, 16, chamfer=0.05, center=(x, z))
        ellipsoid(awning_b, (x, y + 0.6, z), (0.4, 0.3, 0.4), rings=4, segments=8)

    for x in (-3.8, 0.0, 3.8):
        pie(x, top - 0.15, -2.9)
    # Pie tower on a little shelf behind the counter.
    block(wood_dark, (3.6, 2.6, 2.6), (3.4, 0.3, 2.6), bevel=0.06)
    for i in range(3):
        pie(3.6, 2.75 + 0.55 * i, 2.6, r=1.2 - 0.1 * i)
    block(wood_dark, (-3.6, 2.6, 2.6), (3.4, 0.3, 2.6), bevel=0.06)
    pie(-3.6, 2.75, 2.6)
    return m


def build_harvest_arch():
    """Event-square entrance: stacked hay-bale pillars, 'HARVEST FEAST' board, leaf garland."""
    m = Model("Harvest_Arch", "ground centre; front -Z; walkway |x| <= 6.6; Sign front face at z = -0.21", budget=3500)
    hay = m.piece("Hay", HAY)
    twine = m.piece("Twine", TWINE)
    frame = m.piece("Frame", WOOD_DARK)
    sign = m.piece("Sign", CREAM)
    leaf_o = m.piece("LeafOrange", ORANGE)
    leaf_r = m.piece("LeafRed", TOY_RED)
    leaf_y = m.piece("LeafYellow", YELLOW)
    for x in (-9.0, 9.0):
        for k in range(4):
            y = 1.2 + 2.4 * k
            if k % 2 == 0:
                block(hay, (x, y, 0.0), (4.4, 2.4, 3.2), bevel=0.4, segments=2)
                for dx in (-1.1, 1.1):
                    block(twine, (x + dx, y, 0.0), (0.28, 2.48, 3.28), bevel=0.08)
            else:
                block(hay, (x, y, 0.0), (3.2, 2.4, 4.4), bevel=0.4, segments=2)
                for dz in (-1.1, 1.1):
                    block(twine, (x, y, dz), (3.28, 2.48, 0.28), bevel=0.08)
        pumpkin(leaf_o, frame, (x, 9.6, 0.0), r=1.5, h=1.1, rings=6, segments=14)
    sign_frame(frame, sign, (0.0, 11.0, 0.0), (17.0, 3.6), border=0.45, depth=0.6)
    for x in (-8.2, 8.2):
        block(frame, (x, 10.0, 0.25), (0.6, 2.4, 0.6), bevel=0.06)
    # Garland of autumn leaves along the board's bottom edge.
    pieces = (leaf_o, leaf_r, leaf_y)
    for i, x in enumerate(lin(-7.6, 7.6, 15)):
        sag = 0.5 * (1.0 - (x / 8.0) ** 2)
        block(pieces[i % 3], (x, 9.0 - sag, -0.45), (0.9, 0.7, 0.2), bevel=0.06)
    return m


BUILDERS = {
    "Harvest_HayBale": build_hay_bale,
    "Harvest_Pumpkin": build_pumpkin,
    "Harvest_Cornucopia": build_cornucopia,
    "Harvest_StringLights": build_string_lights,
    "Harvest_AutumnTree": build_autumn_tree,
    "Harvest_TurkeyStatue": build_turkey_statue,
    "Harvest_PieStand": build_pie_stand,
    "Harvest_Arch": build_harvest_arch,
    "Harvest_CornucopiaSmall": build_cornucopia_small,
    "Harvest_CornucopiaMini": build_cornucopia_mini,
    "Harvest_PumpkinPile": build_pumpkin_pile,
    "Harvest_Scarecrow": build_scarecrow,
    "Harvest_Garland": build_garland,
}
