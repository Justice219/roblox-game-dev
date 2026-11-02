"""
eggs.py — one hatchable egg per area tier (10) + the Harvest Feast "Harvest Egg" (spec §8, §10).

Every egg is a real two-part SHELL with thickness, split along a zig-zag crack so the hatch
animation can crack it open:

    ShellTop*      upper shell + every decoration that sits above the crack   (group "ShellTop")
    ShellBottom*   lower shell + every decoration that sits below the crack   (group "ShellBottom")

Each half is a closed solid (outer skin + inner skin + the jagged broken rim), so when the top
lifts off you see a clean, thick, toothed edge — no holes or back-faces. Decorations never cross
the crack band, so nothing has to be split.

Hatch animation recipe (client): shake the whole model; then rotate every `ShellTop*` piece about
the HINGE (back of the crack, see pivot string `joints ShellTop@(0,y,z)`) by ~+110 deg around +X
(a positive angle swings the top back over the hinge, like a crate lid) while lifting it ~0.5
studs; optionally tip `ShellBottom*` pieces apart; then reveal the pet.

Coordinates: Roblox space; ORIGIN = ground point under the egg (egg bottom touches y = 0); the
decorated "face" of the egg looks toward -Z (the stand's front). Eggs are 3.0 studs tall, 2.3 wide.
Material: shells `StudsSmall` (half-stud cells read as a toy at this size), glows `Neon`.

Model keys (area tier -> key -> theme):
    1  GarageEgg      sky-blue shell, white wrench plates, steel bolts, hazard band
    2  StandEgg       lemon shell, red scalloped awning, red-white candy cap, gold coins
    3  BoomDashEgg    toy-red shell, white speed lines, yellow lightning bolt, black wheel discs
    4  MineEgg        stone-grey shell, glowing green crystal clusters, darker rock spots
    5  LabEgg         clean white shell, mint band, glowing bubbles, radiation badge
    6  FactoryEgg     orange shell, steel gear plates, yellow/black hazard band
    7  SiloEgg        steel shell, red rocket fins round the base, hazard band, trefoil badge
    8  MegastoreEgg   pink shell, gold stars + sparkle, purple price tag
    9  SpaceEgg       navy shell, Neon star field, ringed planet + moon decals
    10 MegaEgg        gold shell, glowing green reactor band + trefoils, pink gem studs, crown rim
    -  HarvestEgg     pumpkin-ribbed orange shell, green stem + leaf + vine curl, hay band, berries

Build: /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only GarageEgg,...
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import (
    CONCRETE,
    CONCRETE_DARK,
    CREAM,
    DARK_STEEL,
    GLOW_GREEN,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LEAF,
    MINT,
    Model,
    ORANGE,
    PINK,
    PURPLE,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    TYRE,
    WHITE,
    WOOD_DARK,
    YELLOW,
)
from snkit.kit import trefoil
from snkit.shapes import add_faces, cylinder, ellipsoid

from models._critter_kit import (
    GOLD,
    GOLD_DARK,
    HOT_PINK,
    NAVY,
    SNOW,
    SUN_GLOW,
    WATTLE_RED,
    frame,
    oriented_ellipsoid,
    plate,
    star_outline,
    tube,
    tup,
)

EGG_H = 3.0  # total height (studs)
EGG_R = 1.15  # widest radius
BOTTOM_A = 1.25  # height of the lower half-ellipse (widest ring sits at y = BOTTOM_A)
TOP_A = EGG_H - BOTTOM_A  # taller, pointier upper half
CRACK_PHI = 1.62  # polar angle (radians from the bottom pole) of the crack's centre line
CRACK_AMP = 0.11  # zig-zag amplitude (radians)
SEGMENTS = 20  # around (even: the zig-zag alternates up/down per column)
SHELL_T = 0.11  # shell thickness (studs)
BUDGET = 3000


# ------------------------------------------------------------------------------------------------
# Egg surface maths
# ------------------------------------------------------------------------------------------------


def egg_point(yaw: float, phi: float, ribs: int = 0, rib_depth: float = 0.0) -> Vector:
    """
    Point on the egg skin. phi = polar angle from the bottom pole (0) to the top pole (pi); yaw in
    radians, 0 = front (-Z), increasing toward +X. `ribs` > 0 adds pumpkin lobes.
    """
    a = BOTTOM_A if phi <= math.pi / 2 else TOP_A
    y = BOTTOM_A - math.cos(phi) * a
    r = EGG_R * math.sin(phi)
    if ribs:
        r *= 1.0 - rib_depth * (0.5 - 0.5 * math.cos(ribs * yaw)) ** 2
    return Vector((r * math.sin(yaw), y, -r * math.cos(yaw)))


def egg_frame(yaw_deg: float, phi: float, ribs: int = 0, rib_depth: float = 0.0):
    """(point, outward normal) on the egg skin at yaw (DEGREES) and polar angle phi (radians)."""
    yaw = math.radians(yaw_deg)
    p = egg_point(yaw, phi, ribs, rib_depth)
    e = 1e-3
    du = egg_point(yaw + e, phi, ribs, rib_depth) - egg_point(yaw - e, phi, ribs, rib_depth)
    dv = egg_point(yaw, phi + e, ribs, rib_depth) - egg_point(yaw, phi - e, ribs, rib_depth)
    if du.length < 1e-9:  # exactly on a pole: the yaw derivative vanishes
        return p, Vector((0.0, -1.0 if phi < math.pi / 2 else 1.0, 0.0))
    n = dv.cross(du).normalized()
    if n.dot(p - Vector((0, BOTTOM_A, 0))) < 0:
        n = -n
    return p, n


def phi_at_height(y: float) -> float:
    """Inverse of the egg profile: polar angle whose skin height is y."""
    if y <= BOTTOM_A:
        return math.acos(max(-1.0, min(1.0, (BOTTOM_A - y) / BOTTOM_A)))
    return math.acos(max(-1.0, min(1.0, (BOTTOM_A - y) / TOP_A)))


def crack_phi(column: int) -> float:
    """Zig-zag crack latitude for a column: alternates CRACK_AMP above / below CRACK_PHI."""
    return CRACK_PHI + (CRACK_AMP if column % 2 == 0 else -CRACK_AMP)


def build_shell(top, bottom, rings_bottom=6, rings_top=8, ribs=0, rib_depth=0.0):
    """
    Two closed, thick egg halves split on the zig-zag crack.
    Each column s keeps its own crack latitude, and every ring is a lerp between the pole and the
    crack, so the zig-zag is exact with no T-junctions. Inner skin = outer skin pulled toward the
    egg's centre by SHELL_T along the normal; the rim joins them along the crack.
    """
    S = SEGMENTS

    def skin(phi_fn, rings, inner):
        pts = []
        for k in range(rings + 1):
            for s in range(S):
                yaw_deg = 360.0 * s / S
                phi = phi_fn(s, k / rings)
                p, n = egg_frame(yaw_deg, phi, ribs, rib_depth)
                if inner:
                    p = p - n * SHELL_T
                pts.append(tup(p))
        return pts

    def half(piece, phi_fn, rings):
        outer = skin(phi_fn, rings, False)
        inner = skin(phi_fn, rings, True)
        verts = outer + inner
        off = len(outer)
        faces = []
        # Ring 0 (k = 0) is the exact pole (all S points coincide): its quads collapse into a
        # triangle fan when snkit.export.realize welds the coincident pole points (remove_doubles).
        for k in range(rings):
            for s in range(S):
                s2 = (s + 1) % S
                a, b = k * S + s, k * S + s2
                c, d = (k + 1) * S + s2, (k + 1) * S + s
                faces.append((a, b, c, d))
                faces.append((off + d, off + c, off + b, off + a))
        # Broken rim: last outer ring <-> last inner ring.
        last = rings * S
        for s in range(S):
            s2 = (s + 1) % S
            faces.append((last + s2, last + s, off + last + s, off + last + s2))
        add_faces(piece, verts, faces)

    # Bottom: pole (phi 0) -> crack.  Top: pole (phi pi) -> crack (rings run from the top pole).
    half(bottom, lambda s, f: crack_phi(s) * f, rings_bottom)
    half(top, lambda s, f: math.pi - (math.pi - crack_phi(s)) * f, rings_top)


def _new_egg(key: str, theme: str) -> Model:
    """Egg model with the shared pivot / hinge description."""
    hinge = egg_point(math.pi, CRACK_PHI)
    pivot = (
        f"ground point under the egg (bottom at y = 0); decorated face toward -Z; {theme}; "
        f"crack centre y = {egg_point(0, CRACK_PHI).y:.2f}; "
        f"joints ShellTop@(0,{hinge.y:.2f},{hinge.z:.2f})"
    )
    return Model(key, pivot, budget=BUDGET)


def _shells(m, color, ribs=0, rib_depth=0.0, material="StudsSmall"):
    """Create ShellTop / ShellBottom pieces in `color` and build the cracked shell into them."""
    top = m.piece("ShellTop", color, material=material)
    bottom = m.piece("ShellBottom", color, material=material)
    build_shell(top, bottom, ribs=ribs, rib_depth=rib_depth)
    return top, bottom


# Safe latitude bands (decorations stay clear of the crack zig-zag ± margin).
TOP_BAND = (CRACK_PHI + CRACK_AMP + 0.12, math.pi - 0.15)
BOTTOM_BAND = (0.2, CRACK_PHI - CRACK_AMP - 0.12)


def _blob_on(piece, yaw, phi, size, flat=0.06, lift=0.0, up=(0, 1, 0), rings=4, segments=10):
    """Squashed disc / spot stuck to the shell at (yaw deg, phi). Small dots: rings=3, segments=8."""
    p, n = egg_frame(yaw, phi)
    oriented_ellipsoid(piece, tup(p + n * (lift - flat * 0.3)), (size, size, flat), normal=tup(n), up=up, rings=rings, segments=segments)


def _plate_on(piece, outline, yaw, phi, thick=0.07, lift=0.02, up=(0, 1, 0)):
    """Flat 2-D decal plate (star, bolt, wrench) stuck to the shell at (yaw deg, phi)."""
    p, n = egg_frame(yaw, phi)
    plate(piece, outline, tup(p + n * (lift + thick * 0.25)), tup(n), up, thick)


def _band(piece, phi, width=0.14, proud=0.05, segments=24):
    """Raised ring band following one latitude (must lie fully inside one half)."""
    pts = []
    for s in range(segments):
        p, n = egg_frame(360.0 * s / segments, phi)
        pts.append(tup(p + n * (proud * 0.3)))
    tube(piece, pts, width * 0.5, sides=5, closed=True)


def _band_stripes(piece_a, piece_b, phi, count=16, width=0.2, proud=0.05):
    """Alternating two-colour ring band (hazard stripes) along one latitude."""
    for i in range(count):
        piece = piece_a if i % 2 == 0 else piece_b
        pts = []
        steps = 2  # 2 segments per stripe: smooth enough at egg scale, ~26 tris per stripe
        for k in range(steps + 1):
            yaw = 360.0 * (i + k / steps) / count
            p, n = egg_frame(yaw, phi)
            pts.append(tup(p + n * (proud * 0.3)))
        tube(piece, pts, width * 0.5, sides=5)


def _cone_on(piece, yaw, phi, length, radius, tilt=(0.0, 0.0, 0.0), segments=6):
    """Crystal / spike cone growing out of the shell at (yaw deg, phi)."""
    p, n = egg_frame(yaw, phi)
    d = (n + Vector(tilt)).normalized()
    cylinder(piece, tup(p - d * 0.1), tup(p + d * length), radius, segments=segments, radius_b=radius * 0.12)


def _wrench_outline(size):
    """Chunky cartoon wrench (open jaw at the top) as a 2-D outline."""
    s = size
    return [(-0.09 * s, -0.5 * s), (0.09 * s, -0.5 * s), (0.09 * s, 0.22 * s), (0.22 * s, 0.32 * s), (0.2 * s, 0.52 * s),
            (0.08 * s, 0.4 * s), (-0.08 * s, 0.4 * s), (-0.2 * s, 0.52 * s), (-0.22 * s, 0.32 * s), (-0.09 * s, 0.22 * s)]


def _bolt_outline(size):
    """Lightning bolt outline."""
    s = size
    return [(-0.1 * s, 0.5 * s), (0.25 * s, 0.5 * s), (0.05 * s, 0.1 * s), (0.25 * s, 0.1 * s), (-0.2 * s, -0.5 * s),
            (-0.02 * s, -0.05 * s), (-0.22 * s, -0.05 * s)]


def _gear_outline(r, teeth=8):
    """Gear (cog) outline with square teeth."""
    pts = []
    for i in range(teeth):
        a0 = 2 * math.pi * i / teeth
        for frac, rad in ((0.0, r * 0.78), (0.18, r * 0.78), (0.24, r), (0.5, r), (0.56, r * 0.78), (0.82, r * 0.78)):
            a = a0 + frac * 2 * math.pi / teeth
            pts.append((rad * math.cos(a), rad * math.sin(a)))
    return pts


# ------------------------------------------------------------------------------------------------
# Area eggs
# ------------------------------------------------------------------------------------------------


def build_garage_egg():
    """Area 1 Garage Lab: sky-blue shell, white wrench plates, steel bolts, hazard stripe band."""
    m = _new_egg("GarageEgg", "Garage Lab egg (area 1)")
    _shells(m, SKY_BLUE)
    tdeco = m.piece("ShellTopDeco", WHITE, material="StudsSmall")
    for yaw in (0, 120, 240):
        _plate_on(tdeco, _wrench_outline(0.9), yaw, 2.15, up=(0.3, 1, 0))
    bolts = m.piece("ShellTopBolts", STEEL, material="Smooth")
    for yaw in (60, 180, 300):
        p, n = egg_frame(yaw, 2.1)
        plate(bolts, [(0.13 * math.cos(math.radians(60 * k)), 0.13 * math.sin(math.radians(60 * k))) for k in range(6)], tup(p + n * 0.04), tup(n), (0, 1, 0), 0.09)
    yb = m.piece("ShellBottomHazardYellow", HAZARD_YELLOW, material="StudsSmall")
    bb = m.piece("ShellBottomHazardBlack", HAZARD_BLACK, material="StudsSmall")
    _band_stripes(yb, bb, 1.05, count=16, width=0.26)
    glow = m.piece("ShellBottomGlow", GLOW_GREEN, material="Neon")
    p, n = egg_frame(0, 1.32)
    trefoil(glow, tup(p + n * 0.04), 0.22, 0.06, normal=tup(n))
    return m


def build_stand_egg():
    """Area 2 Nuke Stand: lemon shell, red scalloped awning edge, candy-striped cap, gold coins."""
    m = _new_egg("StandEgg", "Nuke Stand egg (area 2)")
    _shells(m, YELLOW)
    red = m.piece("ShellTopAwning", TOY_RED, material="StudsSmall")
    white = m.piece("ShellTopStripe", WHITE, material="StudsSmall")
    phi = TOP_BAND[0] + 0.12
    for i in range(12):  # scalloped awning edge
        _blob_on(red, 360 * i / 12, phi, 0.24, flat=0.08)
    _band_stripes(red, white, 2.55, count=10, width=0.22)
    for yaw in range(0, 360, 36):
        _blob_on(white, yaw + 18, 2.85, 0.12, flat=0.06, rings=3, segments=8)
    coins = m.piece("ShellBottomCoins", GOLD, material="Smooth")
    for k, (yaw, phi) in enumerate(((0, 1.0), (55, 1.15), (-55, 1.15), (130, 0.95), (-130, 0.95), (180, 1.2))):
        p, n = egg_frame(yaw, phi)
        oriented_ellipsoid(coins, tup(p + n * 0.02), (0.22, 0.22, 0.06), normal=tup(n), rings=3, segments=12)
    dark = m.piece("ShellBottomCoinMark", GOLD_DARK, material="Smooth")
    for yaw, phi in ((0, 1.0), (55, 1.15), (-55, 1.15)):
        _plate_on(dark, star_outline(0.12, 0.055), yaw, phi, thick=0.04, lift=0.07)
    return m


def build_boomdash_egg():
    """Area 3 BoomDash Delivery: red shell, white speed lines, yellow lightning bolt, wheel discs."""
    m = _new_egg("BoomDashEgg", "BoomDash Delivery egg (area 3)")
    _shells(m, TOY_RED)
    bolt = m.piece("ShellTopBolt", YELLOW, material="StudsSmall")
    _plate_on(bolt, _bolt_outline(0.9), 0, 2.2, thick=0.08)
    lines = m.piece("ShellTopLines", WHITE, material="StudsSmall")
    for yaw0 in (70, -70):
        for k, phi in enumerate((1.95, 2.15, 2.35)):
            pts = []
            for j in range(5):
                yaw = yaw0 + (j - 2) * 8 + (12 if yaw0 > 0 else -12) * (k % 2)
                p, n = egg_frame(yaw, phi)
                pts.append(tup(p + n * 0.02))
            tube(lines, pts, 0.055, sides=5)
    wheels = m.piece("ShellBottomWheels", TYRE, material="StudsSmall")
    hubs = m.piece("ShellBottomHubs", WHITE, material="Smooth")
    for yaw in (90, -90, 0, 180):
        p, n = egg_frame(yaw, 1.05)
        oriented_ellipsoid(wheels, tup(p + n * 0.04), (0.36, 0.36, 0.1), normal=tup(n), rings=4, segments=14)
        oriented_ellipsoid(hubs, tup(p + n * 0.11), (0.14, 0.14, 0.05), normal=tup(n), rings=3, segments=10)
    return m


def build_mine_egg():
    """Area 4 Glow Rock Mine: stone shell with glowing green crystal clusters and darker rock spots."""
    m = _new_egg("MineEgg", "Glow Rock Mine egg (area 4)")
    _shells(m, CONCRETE)
    t_glow = m.piece("ShellTopCrystals", GLOW_GREEN, material="Neon")
    b_glow = m.piece("ShellBottomCrystals", GLOW_GREEN, material="Neon")
    for yaw, phi, length in ((20, 2.2, 0.55), (35, 2.05, 0.35), (5, 2.0, 0.3), (200, 2.4, 0.5), (215, 2.25, 0.32), (300, 2.7, 0.4)):
        _cone_on(t_glow, yaw, phi, length, 0.13, tilt=(0.1, 0.3, 0))
    for yaw, phi, length in ((-40, 1.05, 0.5), (-25, 1.2, 0.32), (-55, 0.9, 0.3), (140, 1.0, 0.45), (155, 1.15, 0.3)):
        _cone_on(b_glow, yaw, phi, length, 0.13, tilt=(0.1, -0.2, 0))
    t_rock = m.piece("ShellTopRock", CONCRETE_DARK, material="StudsSmall")
    b_rock = m.piece("ShellBottomRock", CONCRETE_DARK, material="StudsSmall")
    for yaw, phi, s in ((90, 2.3, 0.2), (130, 2.0, 0.16), (-100, 2.15, 0.22), (-160, 2.6, 0.14)):
        _blob_on(t_rock, yaw, phi, s, flat=0.07)
    for yaw, phi, s in ((40, 1.0, 0.24), (90, 0.75, 0.18), (-120, 0.8, 0.2), (180, 1.25, 0.16), (10, 0.6, 0.16)):
        _blob_on(b_rock, yaw, phi, s, flat=0.07)
    return m


def build_lab_egg():
    """Area 5 Enrichment Lab: white shell, mint band, glowing bubbles, radiation badge."""
    m = _new_egg("LabEgg", "Enrichment Lab egg (area 5)")
    _shells(m, SNOW)
    band = m.piece("ShellBottomBand", MINT, material="StudsSmall")
    _band(band, 0.98, width=0.26)
    badge = m.piece("ShellBottomBadge", HAZARD_YELLOW, material="Smooth")
    p, n = egg_frame(0, 1.3)
    oriented_ellipsoid(badge, tup(p + n * 0.03), (0.3, 0.3, 0.06), normal=tup(n), rings=3, segments=14)
    mark = m.piece("ShellBottomMark", HAZARD_BLACK, material="Smooth")
    trefoil(mark, tup(p + n * 0.09), 0.24, 0.04, normal=tup(n))
    bubbles = m.piece("ShellTopBubbles", GLOW_GREEN, material="Neon")
    for yaw, phi, s in ((0, 2.15, 0.17), (25, 2.4, 0.12), (-20, 2.55, 0.09), (110, 2.1, 0.15), (140, 2.4, 0.1),
                        (-120, 2.2, 0.16), (-150, 2.5, 0.1), (200, 2.0, 0.13), (60, 2.7, 0.08)):
        p, n = egg_frame(yaw, phi)
        ellipsoid(bubbles, tup(p + n * (s * 0.3)), (s, s, s), rings=4, segments=8)
    return m


def build_factory_egg():
    """Area 6 Rocket Factory: orange shell, steel gear plates on top, hazard stripe band below."""
    m = _new_egg("FactoryEgg", "Rocket Factory egg (area 6)")
    _shells(m, ORANGE)
    gears = m.piece("ShellTopGears", DARK_STEEL, material="StudsSmall")
    for yaw, phi, r in ((0, 2.2, 0.36), (120, 2.35, 0.3), (240, 2.25, 0.32)):
        _plate_on(gears, _gear_outline(r), yaw, phi, thick=0.08)
    hubs = m.piece("ShellTopHubs", STEEL, material="Smooth")
    for yaw, phi in ((0, 2.2), (120, 2.35), (240, 2.25)):
        _blob_on(hubs, yaw, phi, 0.12, flat=0.05, lift=0.1)
    yb = m.piece("ShellBottomHazardYellow", HAZARD_YELLOW, material="StudsSmall")
    bb = m.piece("ShellBottomHazardBlack", HAZARD_BLACK, material="StudsSmall")
    _band_stripes(yb, bb, 1.1, count=18, width=0.3)
    _band_stripes(bb, yb, 0.62, count=12, width=0.22)
    return m


def build_silo_egg():
    """Area 7 Launch Silos: steel shell, red rocket fins round the base, hazard band, trefoil badge."""
    m = _new_egg("SiloEgg", "Launch Silos egg (area 7)")
    _shells(m, STEEL)
    fins = m.piece("ShellBottomFins", TOY_RED, material="StudsSmall")
    for k in range(4):
        yaw = 45 + 90 * k
        p, n = egg_frame(yaw, 0.85)
        out = Vector((n.x, 0, n.z)).normalized()
        plate(fins, [(0.0, -0.1), (0.42, -0.25), (0.42, 0.05), (0.0, 0.45)], tup(p - out * 0.05), tup(Vector((-out.z, 0, out.x))), (0, 1, 0), 0.1)
    yb = m.piece("ShellBottomHazardYellow", HAZARD_YELLOW, material="StudsSmall")
    bb = m.piece("ShellBottomHazardBlack", HAZARD_BLACK, material="StudsSmall")
    _band_stripes(yb, bb, 1.25, count=16, width=0.24)
    nose = m.piece("ShellTopNose", TOY_RED, material="StudsSmall")
    _band(nose, 2.75, width=0.22)
    p, n = egg_frame(0, math.pi - 0.02)
    ellipsoid(nose, tup(p), (0.2, 0.12, 0.2), rings=4, segments=10)
    badge = m.piece("ShellTopBadge", HAZARD_YELLOW, material="Smooth")
    p, n = egg_frame(0, 2.15)
    oriented_ellipsoid(badge, tup(p + n * 0.03), (0.3, 0.3, 0.06), normal=tup(n), rings=3, segments=14)
    glow = m.piece("ShellTopGlow", GLOW_GREEN, material="Neon")
    trefoil(glow, tup(p + n * 0.09), 0.24, 0.04, normal=tup(n))
    return m


def build_megastore_egg():
    """Area 8 Nuke Megastore: pink shell, gold stars + sparkles, purple price tag."""
    m = _new_egg("MegastoreEgg", "Nuke Megastore egg (area 8)")
    _shells(m, PINK)
    t_gold = m.piece("ShellTopStars", GOLD, material="StudsSmall")
    b_gold = m.piece("ShellBottomStars", GOLD, material="StudsSmall")
    for yaw, phi, s in ((0, 2.2, 0.34), (95, 2.4, 0.24), (-95, 2.3, 0.26), (180, 2.15, 0.3), (40, 2.7, 0.16)):
        _plate_on(t_gold, star_outline(s, s * 0.46), yaw, phi, thick=0.08)
    for yaw, phi, s in ((60, 1.0, 0.24), (-60, 1.1, 0.2), (150, 0.9, 0.22), (-150, 1.2, 0.18)):
        _plate_on(b_gold, star_outline(s, s * 0.46), yaw, phi, thick=0.08)
    tag = m.piece("ShellBottomTag", PURPLE, material="StudsSmall")
    _plate_on(tag, [(-0.32, -0.22), (0.2, -0.22), (0.4, 0.0), (0.2, 0.22), (-0.32, 0.22)], 0, 1.25, thick=0.08, up=(0.25, 1, 0))
    hole = m.piece("ShellBottomTagHole", SNOW, material="Smooth")
    p, n = egg_frame(-6, 1.25)
    oriented_ellipsoid(hole, tup(p + n * 0.1), (0.06, 0.06, 0.03), normal=tup(n), rings=3, segments=8)
    sparkle = m.piece("ShellTopSparkle", SUN_GLOW, material="Neon")
    for yaw, phi in ((60, 2.05), (-140, 2.55), (150, 2.6)):
        _plate_on(sparkle, star_outline(0.12, 0.03, points=4), yaw, phi, thick=0.05, lift=0.04)
    return m


def build_space_egg():
    """Area 9 Space Port: navy shell, Neon star field, a ringed planet and a moon decal."""
    m = _new_egg("SpaceEgg", "Space Port egg (area 9)")
    _shells(m, NAVY)
    t_stars = m.piece("ShellTopStars", SUN_GLOW, material="Neon")
    b_stars = m.piece("ShellBottomStars", SUN_GLOW, material="Neon")
    for yaw, phi, s in ((30, 2.1, 0.13), (80, 2.5, 0.09), (150, 2.2, 0.12), (-60, 2.35, 0.1), (-130, 2.05, 0.13), (200, 2.7, 0.08), (-20, 2.8, 0.07)):
        _plate_on(t_stars, star_outline(s, s * 0.45), yaw, phi, thick=0.05)
    for yaw, phi, s in ((40, 0.9, 0.11), (100, 1.2, 0.09), (-80, 1.0, 0.12), (170, 0.8, 0.1), (-150, 1.25, 0.08)):
        _plate_on(b_stars, star_outline(s, s * 0.45), yaw, phi, thick=0.05)
    planet = m.piece("ShellBottomPlanet", ORANGE, material="StudsSmall")
    p, n = egg_frame(-10, 1.25)
    oriented_ellipsoid(planet, tup(p + n * 0.08), (0.3, 0.3, 0.12), normal=tup(n), rings=5, segments=12)
    ring = m.piece("ShellBottomPlanetRing", SNOW, material="Smooth")
    s_, u_, n_ = frame(n, (0.4, 1, 0))
    pts = [tup(p + n * 0.12 + s_ * (0.5 * math.cos(2 * math.pi * i / 16)) + u_ * (0.14 * math.sin(2 * math.pi * i / 16)) + n_ * (0.06 * math.sin(2 * math.pi * i / 16))) for i in range(16)]
    tube(ring, pts, 0.04, sides=5, closed=True)
    moon = m.piece("ShellTopMoon", CREAM, material="StudsSmall")
    p, n = egg_frame(5, 2.25)
    oriented_ellipsoid(moon, tup(p + n * 0.04), (0.26, 0.26, 0.08), normal=tup(n), rings=4, segments=12)
    craters = m.piece("ShellTopCraters", CONCRETE_DARK, material="Smooth")
    s_, u_, n_ = frame(n)
    for dx, dy, r in ((-0.08, 0.06, 0.06), (0.09, -0.05, 0.05), (0.05, 0.12, 0.035)):
        oriented_ellipsoid(craters, tup(p + n * 0.12 + s_ * dx + u_ * dy), (r, r, 0.025), normal=tup(n), rings=3, segments=8)
    return m


def build_mega_egg():
    """Area 10 Mega Nuclear Facility: gold shell, glowing reactor band + trefoils, gem studs, crown rim."""
    m = _new_egg("MegaEgg", "Mega Nuclear Facility egg (area 10)")
    _shells(m, GOLD)
    glow = m.piece("ShellBottomGlow", GLOW_GREEN, material="Neon")
    _band(glow, 0.95, width=0.2)
    for yaw in (0, 120, 240):
        p, n = egg_frame(yaw, 1.3)
        trefoil(glow, tup(p + n * 0.05), 0.2, 0.05, normal=tup(n))
    gems = m.piece("ShellTopGems", HOT_PINK, material="Smooth")
    for k in range(8):
        p, n = egg_frame(22.5 + 45 * k, 2.05)
        oriented_ellipsoid(gems, tup(p + n * 0.05), (0.11, 0.13, 0.08), normal=tup(n), rings=3, segments=6)
    crown = m.piece("ShellTopCrown", GOLD_DARK, material="StudsSmall")
    _band(crown, TOP_BAND[0] + 0.02, width=0.2)
    for k in range(8):
        p, n = egg_frame(45 * k, TOP_BAND[0] + 0.1)
        plate(crown, [(-0.15, 0), (0.15, 0), (0, 0.32)], tup(p + n * 0.05), tup(n), (0, 1, 0), 0.07)
    tglow = m.piece("ShellTopGlow", GLOW_GREEN, material="Neon")
    p, n = egg_frame(0, 2.45)
    trefoil(tglow, tup(p + n * 0.05), 0.24, 0.05, normal=tup(n))
    return m


def build_harvest_egg():
    """Harvest Feast egg: pumpkin-ribbed orange shell, stem + leaf + vine curl, hay band, berries."""
    m = Model("HarvestEgg", "", budget=BUDGET)
    hinge = egg_point(math.pi, CRACK_PHI)
    m.pivot = (
        f"ground point under the egg (bottom at y = 0); decorated face toward -Z; Harvest Feast event egg; "
        f"crack centre y = {egg_point(0, CRACK_PHI).y:.2f}; joints ShellTop@(0,{hinge.y:.2f},{hinge.z:.2f})"
    )
    _shells(m, (240, 128, 40), ribs=8, rib_depth=0.09)
    stem = m.piece("ShellTopStem", WOOD_DARK, material="StudsSmall")
    top = egg_point(0, math.pi)
    cylinder(stem, tup(top - Vector((0, 0.1, 0))), tup(top + Vector((0.06, 0.38, 0.04))), 0.13, segments=7, radius_b=0.1)
    leaf = m.piece("ShellTopLeaf", LEAF, material="StudsSmall")
    leaf_outline = [(0, 0), (0.18, 0.12), (0.36, 0.1), (0.3, 0.26), (0.42, 0.42), (0.2, 0.4), (0.0, 0.6),
                    (-0.2, 0.4), (-0.42, 0.42), (-0.3, 0.26), (-0.36, 0.1), (-0.18, 0.12)]
    plate(leaf, leaf_outline, tup(top + Vector((0.12, 0.08, -0.05))), (0.3, 1, -0.4), (1, 0, 0.3), 0.05)
    vine = [tup(top + Vector((-0.05, 0.1, 0.02)))]
    for i in range(1, 12):
        a = i * 0.8
        r = 0.08 + 0.025 * i
        vine.append(tup(top + Vector((-0.12 - r * math.cos(a), 0.12 + 0.012 * i, r * math.sin(a)))))
    tube(leaf, vine, 0.03, sides=4)
    hay = m.piece("ShellBottomHay", (246, 214, 110), material="StudsSmall")
    _band(hay, 1.15, width=0.26)
    _band(hay, 0.75, width=0.16)
    berries = m.piece("ShellBottomBerries", WATTLE_RED, material="Smooth")
    for k in range(6):
        p, n = egg_frame(60 * k + 30, 0.95)
        for j in range(2):
            ellipsoid(berries, tup(p + n * 0.08 + Vector((0.08 * (j - 0.5), 0.05 * j, 0))), (0.08, 0.08, 0.08), rings=4, segments=8)
    glow = m.piece("ShellTopGlow", SUN_GLOW, material="Neon")
    p, n = egg_frame(0, 2.2)
    oriented_ellipsoid(glow, tup(p + n * 0.02), (0.16, 0.18, 0.05), normal=tup(n), rings=4, segments=10)
    for side in (-1, 1):
        q, nq = egg_frame(side * 30, 2.35)
        plate(glow, [(-0.1, -0.06), (0.1, -0.06), (0.0, 0.12)], tup(q + nq * 0.03), tup(nq), (0, 1, 0), 0.04)
    # Glowing jack-o'-smile under the eyes (a gentle zig-zag along the skin).
    smile_pts = []
    for yaw in range(-24, 25, 6):
        q, nq = egg_frame(yaw, 1.98 - 0.06 * math.cos(math.radians(yaw * 4)))
        smile_pts.append(tup(q + nq * 0.02))
    tube(glow, smile_pts, 0.035, sides=4)
    return m


BUILDERS = {
    "GarageEgg": build_garage_egg,
    "StandEgg": build_stand_egg,
    "BoomDashEgg": build_boomdash_egg,
    "MineEgg": build_mine_egg,
    "LabEgg": build_lab_egg,
    "FactoryEgg": build_factory_egg,
    "SiloEgg": build_silo_egg,
    "MegastoreEgg": build_megastore_egg,
    "SpaceEgg": build_space_egg,
    "MegaEgg": build_mega_egg,
    "HarvestEgg": build_harvest_egg,
}
