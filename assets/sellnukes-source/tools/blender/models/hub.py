"""
hub.py — the central Hub plaza (B8e): ground, ring road, the giant toy-nuke fountain monument and
every hub fixture the systems hang off (egg stands, crate stall, lucky wheel, group chest, codes
board, leaderboards, plot teleport pads, spawn pad) plus street furniture (benches, lamps, trees,
planters).

World layout (docs/superpowers/plans/2026-10-30-sellnukes-build.md "World layout"):
    Hub at the world origin: plaza radius 0-230, ring road 230-260, ground top y = 0.
    Plots i = 1..8 sit outside the ring road at yaw (i-1) * 45 deg (yaw measured from +Z toward +X,
    i.e. CFrame.Angles(0, yaw, 0) * (0, 0, 1) = (sin yaw, 0, cos yaw)).

Plaza structure (all instanced so the hub is a handful of unique meshes):
    Lobby centre r 0-86.5 (Hub_CenterPlaza, Hub_PlazaSpoke, Hub_PlazaGarden, Hub_Monument,
                        Hub_NukeyStatue, Hub_TeleportPad, Hub_SpawnPad, banners, bunting, coins)
                        lives in hub_plaza.py since the owner R55 redesign (L1-lobby).
    Hub_Avenue          x8: radial paved avenue |x| <= 12 from r 84 to r 230 along +Z, with
                        TINTED chevrons pointing to the plot (tint = that plot's colour).
                        Pivot = world origin; spawn at CFrame.Angles(0, (i-1)*45deg, 0).
    Hub_DistrictWedge   x8: the district between two avenues (bisector +Z, yaw +-22.5 deg): paving
                        r 84-230 + a raised grass bed r 92-194 (top y = 0.1) ringed by white curb
                        stones. Pivot = world origin; spawn at yaw 22.5 + 45k deg.
    Hub_RingRoadArc     x8: 45 deg of the ring road r 230-260 centred on +Z (flush curbs, yellow
                        dashes, a zebra crossing where the avenue meets the plot road). Pivot =
                        world origin; spawn at yaw (i-1)*45 deg (same as the plot).
    Stud grids are projected in each MeshPart's object space, so instance seams sit where the
    material changes anyway (avenue edges) or in the middle of empty asphalt (ring road).

Fixtures (pivot = ground centre unless stated, front = -Z; HubLayout.luau places them):
    Hub_EggStand        plinth + pedestal + cradle; egg pivot goes at (0, 4.0, 0). Sign frame on
                        tinted posts behind/above the egg; `Sign` front face = name/price SurfaceGui.
                        `Accent` is tinted per area theme.
    Hub_CrateStall      striped market stall full of supply crates; display spot on the counter at
                        (0, 3.7, -2.9); `Sign` on the awning.
    Hub_LuckyWheelStage round stage, wheel stand, halo of bulbs, pointer, `Sign`. The wheel itself
                        is Hub_LuckyWheel (pivot = axle) at stage pivot * (0, 13, 0) so a client
                        can spin it about its local Z axis.
    Hub_GroupChest      podium + treasure chest body + gems + `Sign`. Lid = Hub_GroupChestLid,
                        pivot = hinge at chest pivot * (0, 4.8, 2.3); open = rotate about local X
                        (CFrame.Angles(math.rad(-105), 0, 0)).
    Hub_CodesBoard      board on posts with a giant key on top; `Screen` front face (13 x 8.2).
    Hub_Leaderboard     tall board, `Screen` front face (12.8 x 17.8), tinted `Frame`, trophy.
    Hub_Bench / Hub_Lamp / Hub_Tree / Hub_Planter   street furniture (also reused in scenery).

Shared geometry helpers (also imported by plotframe.py, scenery.py, event_harvest.py):
    polar, lin, slab, ring, sector_outline, wedge_outline, strip_outline, rotated, rrect_outline,
    chevron_outline, star_outline, bulb.

Budgets: floors <= 3,000 (one or eight on screen), fixtures <= 3,000, monument <= 6,000 (hero).
"""

import math

from snkit.core import (
    CHARCOAL,
    CREAM,
    DARK_STEEL,
    DEEP_BLUE,
    GLOW_GREEN,
    GRASS,
    LAMP_WARM,
    LEAF,
    LIME,
    Model,
    PINK,
    PURPLE,
    SIDEWALK,
    SKY_BLUE,
    TOY_RED,
    WHITE,
    WOOD,
    WOOD_DARK,
    YELLOW,
    BROWN,
    ROAD,
)
from snkit.kit import block, nuke_body, sign_frame, trefoil
from snkit.shapes import bar, box, cylinder, ellipsoid, extrude_outline, loft, prism, revolve, ring_tube, rot_x, rot_y

TAU = 2 * math.pi

# ---- Hub dimensions (HubLayout.luau mirrors these; change both together) ----------------------
CENTER_R = 84.0  # centre plaza radius (fountain + teleport pad ring)
PLAZA_R = 230.0  # plaza edge = ring road inner edge
ROAD_OUT_R = 260.0  # ring road outer edge = plot entrances
AVENUE_HALF = 12.0  # avenue half-width (|x| <= 12)
BED_IN_R = 92.0  # grass bed inner radius
BED_OUT_R = 194.0  # grass bed outer radius
BED_OFFSET = 16.0  # grass bed edge distance from each avenue axis
BED_TOP = 0.1  # grass bed top (features stand here)
HALF = math.radians(22.5)  # half a sector

STONE = (236, 236, 242)  # warm white stone for pedestals (a touch darker than WHITE trims)
SLATE = (44, 52, 70)  # dark board behind SurfaceGuis (codes, leaderboards)
WATER = (90, 196, 255)  # cartoon fountain water
GEM = (190, 110, 255)  # glowing gem purple
DISTRICT_PAVE = (246, 241, 230)  # warm white district paving (= hub_plaza.py PAVE, owner R55)


# =================================================================================================
# Shared geometry helpers
# =================================================================================================


def polar(r, yaw):
    """(x, z) on the ground plane at radius r and yaw (radians from +Z toward +X)."""
    return (r * math.sin(yaw), r * math.cos(yaw))


def lin(a, b, n):
    """n + 1 evenly spaced values from a to b inclusive."""
    return [a + (b - a) * i / n for i in range(n + 1)]


def slab(piece, outline_at, y0, y1, chamfer=0.25):
    """
    Flat slab from a 2-D outline (x, z) between heights y0 < y1 with a chamfered TOP edge.
    `outline_at(d)` must return the outline inset by d studs, always with the same point count
    (so the loft sections match). chamfer <= 0 gives a straight extrusion.

    Example: slab(piece, sector_outline(230, 260, -0.4, 0.4, 12), -1.0, 0.0, chamfer=0.2)
    """
    if chamfer <= 0:
        extrude_outline(piece, outline_at(0.0), y0, y1)
        return
    c = min(chamfer, (y1 - y0) * 0.45)
    full = outline_at(0.0)
    top = outline_at(c)
    loft(
        piece,
        [
            [(x, y0, z) for x, z in full],
            [(x, y1 - c, z) for x, z in full],
            [(x, y1, z) for x, z in top],
        ],
    )


def ring(piece, r0, r1, y0, y1, segments, chamfer=0.2, center=(0.0, 0.0)):
    """
    Full flat annulus r0..r1 (a disc when r0 == 0) between heights y0..y1, chamfered top edges,
    built by revolving a profile (cheap, perfectly round). center = (x, z).
    """
    c = max(0.0, min(chamfer, (y1 - y0) * 0.45, (r1 - r0) * 0.3))
    cx, cz = center
    if r0 <= 1e-6:
        if c > 0:
            profile = [(0.0, y0), (r1, y0), (r1, y1 - c), (r1 - c, y1), (0.0, y1)]
        else:
            profile = [(0.0, y0), (r1, y0), (r1, y1), (0.0, y1)]
        revolve(piece, profile, center=(cx, 0.0, cz), segments=segments)
        return
    if c > 0:
        profile = [(r0, y0), (r1, y0), (r1, y1 - c), (r1 - c, y1), (r0 + c, y1), (r0, y1 - c)]
    else:
        profile = [(r0, y0), (r1, y0), (r1, y1), (r0, y1)]
    revolve(piece, profile, center=(cx, 0.0, cz), segments=segments, closed=True)


def sector_outline(r0, r1, a0, a1, segments):
    """
    Annular sector r0..r1 between yaws a0 < a1 (radians) with straight radial ends. Inset d moves
    the arcs inward and shifts each radial end d studs (asin(d / r) at radius r). r0 == 0 gives a
    pie slice whose apex insets along the bisector.
    """

    def at(d):
        ro = r1 - d
        da_o = math.asin(min(d / ro, 0.99))
        outer = [polar(ro, a) for a in lin(a0 + da_o, a1 - da_o, segments)]
        if r0 <= 1e-6:
            half = (a1 - a0) / 2
            inner = [polar(d / math.sin(half) if d > 0 else 0.0, a0 + half)]
        else:
            ri = r0 + d
            da_i = math.asin(min(d / ri, 0.99))
            inner = [polar(ri, a) for a in lin(a1 - da_i, a0 + da_i, segments)]
        return outer + inner

    return at


def wedge_outline(r0, r1, half, offset, segments, inner_segments=None):
    """
    Hub district: the region between circles r0 < r1 and two straight lines parallel to the
    radial axes at yaw -half / +half, each moved `offset` studs toward the bisector (+Z).
    That is exactly "everything between two avenues of half-width `offset`". Inset d grows the
    line offsets and shrinks the arcs, so chamfers stay parallel to every edge.
    """
    inner_segments = inner_segments or max(2, segments // 3)

    def at(d):
        c = offset + d

        def corner(r, side):
            # side -1 = left line (axis at yaw -half), +1 = right line (axis at yaw +half).
            u = (side * math.sin(half), math.cos(half))  # line direction (outward)
            n = (-side * math.cos(half), math.sin(half))  # unit normal toward the bisector
            t = math.sqrt(max(r * r - c * c, 1e-6))
            return (c * n[0] + t * u[0], c * n[1] + t * u[1])

        def arc(r, p, q, k):
            a, b = math.atan2(p[0], p[1]), math.atan2(q[0], q[1])
            return [polar(r, a + (b - a) * i / k) for i in range(k + 1)]

        ro, ri = r1 - d, r0 + d
        outer = arc(ro, corner(ro, -1), corner(ro, 1), segments)
        inner = arc(ri, corner(ri, 1), corner(ri, -1), inner_segments)
        return outer + inner

    return at


def wedge_corner(r, half, offset, side):
    """Point where the offset line on `side` (-1 left, +1 right) crosses the circle of radius r."""
    u = (side * math.sin(half), math.cos(half))
    n = (-side * math.cos(half), math.sin(half))
    t = math.sqrt(max(r * r - offset * offset, 1e-6))
    return (offset * n[0] + t * u[0], offset * n[1] + t * u[1])


def strip_outline(r0, r1, half_width, segments):
    """Straight strip |x| <= half_width along +Z whose ends follow the circles r0 and r1."""

    def at(d):
        w = half_width - d
        ri, ro = r0 + d, r1 - d
        outer = [(x, math.sqrt(ro * ro - x * x)) for x in lin(-w, w, segments)]
        inner = [(x, math.sqrt(ri * ri - x * x)) for x in lin(w, -w, segments)]
        return outer + inner

    return at


def rotated(outline_at, yaw):
    """Wrap an outline function so its points are rotated by `yaw` (radians, +Z toward +X)."""
    c, s = math.cos(yaw), math.sin(yaw)

    def at(d):
        return [(x * c + z * s, -x * s + z * c) for x, z in outline_at(d)]

    return at


def rrect_outline(w, depth, radius, segments=4, cx=0.0, cz=0.0):
    """Rounded rectangle (w along X, depth along Z) with corner radius; inset-aware."""

    def at(d):
        hw, hd, r = w / 2 - d, depth / 2 - d, max(radius - d, 0.05)
        pts = []
        for qx, qz, a0 in ((1, 1, 0.0), (1, -1, 90.0), (-1, -1, 180.0), (-1, 1, 270.0)):
            ox, oz = cx + qx * (hw - r), cz + qz * (hd - r)
            for i in range(segments + 1):
                a = math.radians(a0 + 90.0 * i / segments)
                pts.append((ox + r * math.sin(a), oz + r * math.cos(a)))
        return pts

    return at


def chevron_outline(cx, cz, width, height, thickness):
    """Flat '^' chevron pointing +Z centred at (cx, cz): concave hexagon for extrude_outline."""
    hw, hh = width / 2, height / 2
    return [
        (cx - hw, cz - hh),
        (cx, cz + hh),
        (cx + hw, cz - hh),
        (cx + hw - thickness * 0.7, cz - hh - thickness * 0.6),
        (cx, cz + hh - thickness),
        (cx - hw + thickness * 0.7, cz - hh - thickness * 0.6),
    ]


def star_outline(cx, cz, r_out, r_in, points=5, spin=0.0):
    """Flat star (x, z) outline, first tip toward +Z rotated by `spin` radians."""
    pts = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        pts.append(polar(r, spin + math.pi * i / points))
    return [(cx + x, cz + z) for x, z in pts]


def bulb(piece, center, radius=0.32):
    """Tiny low-poly light bulb (Neon piece): 6 x 4 ellipsoid, ~40 triangles."""
    ellipsoid(piece, center, (radius, radius * 1.1, radius), rings=4, segments=6)


def arc_blocks(piece, radius, a0, a1, width, y0, y1, count, bevel=0.12):
    """Curved kerb made of `count` chamfered blocks along a circle (toy kerb stones)."""
    step = (a1 - a0) / count
    chord = 2 * radius * math.sin(step / 2) + 0.12  # tiny overlap so no light leaks between stones
    for i in range(count):
        a = a0 + step * (i + 0.5)
        x, z = polar(radius, a)
        block(piece, (x, (y0 + y1) / 2, z), (chord, y1 - y0, width), bevel=bevel, rot=rot_y(math.degrees(a)))


# =================================================================================================
# Plaza floor
# =================================================================================================


def build_avenue():
    """Radial avenue |x| <= 12 from r 84 to r 230 along +Z, white edge lines, tinted chevrons."""
    m = Model("Hub_Avenue", "world origin; avenue runs along +Z from r 84 to r 230 (top y = 0.03); chevrons point +Z", budget=1200)
    paving = m.piece("Paving", SIDEWALK)
    lines = m.piece("Lines", WHITE)
    chevrons = m.piece("Chevrons", YELLOW, tinted=True)
    # Avenue paving top +0.03: never level with the district paving (0), the centre dais (0.06) or
    # the ring-road asphalt (0), so no seam or fallback box ever shares its plane. Markings sit on
    # their own layers above it (lines +0.07, chevrons +0.09).
    slab(paving, strip_outline(CENTER_R, PLAZA_R, AVENUE_HALF, 6), -1.0, 0.03, chamfer=0.3)
    for x in (-10.4, 10.4):
        box(lines, (x, 0.0, 157.0), (0.9, 0.14, 140.0))
    z = 102.0
    while z < 222.0:
        extrude_outline(chevrons, chevron_outline(0.0, z, 11.0, 6.0, 2.2), -0.05, 0.09)
        z += 20.0
    return m


def build_district_wedge():
    """District between two avenues: paving r 84-230 + grass bed r 92-194 (top 0.1) + curb stones."""
    m = Model(
        "Hub_DistrictWedge",
        "world origin; district centred on +Z (yaw +-22.5 deg between avenue edges); bed top y = 0.1",
        budget=2000,
    )
    # Owner R55 (L1-lobby): warm white paving + lime kerbs, the same palette as the lobby centre
    # (hub_plaza.py PAVE / garden coping), so the districts read as one plaza with it instead of
    # grey concrete; the light-grey avenues stay the "roads" through them.
    paving = m.piece("Paving", DISTRICT_PAVE)
    grass = m.piece("Grass", GRASS)
    curb = m.piece("Curb", LIME)
    slab(paving, wedge_outline(CENTER_R, PLAZA_R, HALF, AVENUE_HALF, 16, 6), -1.0, 0.0, chamfer=0.3)
    slab(grass, wedge_outline(BED_IN_R, BED_OUT_R, HALF, BED_OFFSET, 16, 6), -0.5, BED_TOP, chamfer=0.12)
    # Curb stones: arcs just outside the bed (inner r 91.2, outer r 194.8) + straight sides.
    c_off = BED_OFFSET - 0.8
    for r, count in ((BED_IN_R - 0.8, 4), (BED_OUT_R + 0.8, 10)):
        left = wedge_corner(r, HALF, c_off - 0.8, -1)
        right = wedge_corner(r, HALF, c_off - 0.8, 1)
        a0, a1 = math.atan2(left[0], left[1]), math.atan2(right[0], right[1])
        arc_blocks(curb, r, a0, a1, 1.6, -0.3, 0.45, count)
    for side in (-1, 1):
        p0 = wedge_corner(BED_IN_R - 1.6, HALF, c_off, side)
        p1 = wedge_corner(BED_OUT_R + 1.6, HALF, c_off, side)
        mid = ((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2)
        length = math.dist(p0, p1)
        block(curb, (mid[0], 0.075, mid[1]), (1.6, 0.75, length), bevel=0.12, rot=rot_y(side * 22.5))
    return m


# Half-width of the ring road's mouth: 0.1 inside the plot road's curbs (x = +-10), whose fronts
# reach 0.1 into the mouth, so the mouth's side walls end up INSIDE the curbs (never coplanar).
JUNCTION_HALF = 9.9
RING_CURB_TOP = 0.25  # ring-road curbs stand clearly above the asphalt (z-fight + LOD rule)


def band_to_x(r0, r1, x_cut, a_end, segments, mirror=False):
    """
    Annular band r0..r1 from the straight line x = x_cut (a curb cut) out to yaw a_end (radians,
    > 0); mirror=True gives the -x twin. Inset-aware (chamfered slabs).
    """

    def at(d):
        ri, ro, xc = r0 + d, r1 - d, x_cut + d
        da_o = math.asin(min(d / ro, 0.99))
        da_i = math.asin(min(d / ri, 0.99))
        outer = [polar(ro, a) for a in lin(math.asin(xc / ro), a_end - da_o, segments)]
        inner = [polar(ri, a) for a in lin(a_end - da_i, math.asin(xc / ri), segments)]
        pts = outer + inner
        return [(-x, z) for x, z in pts] if mirror else pts

    return at


def build_ring_road_arc():
    """
    45 deg of ring road (r 230-260) centred on +Z (the plot junction is at yaw 0).

    Layers (z-fight rule, docs/areas-art.md "Z-fighting layer rule"):
        asphalt top 0; centre dashes top +0.04; zebra crossing top +0.05; curbs top +0.25
        (avenues +0.03, so no two of these ever share a plane, even as fallback boxes).
    The outer curb is CUT at the junction (|x| <= 9.9): the asphalt runs out through the cut to the
    straight line z = 260, where the plot road (Plot_Road, straight front at plot z = 0) butts it
    edge to edge (RoBeasts MapGeometry rule: no overlap, straight seam, so LOD can't make it fight).
    Every other asphalt edge meets a raised curb (different height, so curved seams are safe).
    """
    m = Model("Hub_RingRoadArc", "world origin; arc covers yaw -22.5..+22.5 deg, r 230-260; junction mouth at yaw 0", budget=2200)
    asphalt = m.piece("Asphalt", ROAD)
    curb = m.piece("Curb", SIDEWALK)
    dashes = m.piece("Dashes", YELLOW)
    zebra = m.piece("Zebra", WHITE)
    # Asphalt: the 233-257 band plus the junction mouth up to z = 260, as ONE flat polygon.
    a_j = math.asin(JUNCTION_HALF / 257.0)
    outline = [polar(257.0, a) for a in lin(-HALF, -a_j, 8)]
    outline += [(-JUNCTION_HALF, ROAD_OUT_R), (JUNCTION_HALF, ROAD_OUT_R)]
    outline += [polar(257.0, a) for a in lin(a_j, HALF, 8)]
    outline += [polar(233.0, a) for a in lin(HALF, -HALF, 16)]
    extrude_outline(asphalt, outline, -1.0, 0.0)
    # Curbs: full inner curb; outer curb in two halves either side of the junction cut.
    slab(curb, sector_outline(PLAZA_R, 233.0, -HALF, HALF, 16), -1.0, RING_CURB_TOP, chamfer=0.08)
    for mirror in (False, True):
        slab(curb, band_to_x(257.0, ROAD_OUT_R, JUNCTION_HALF, HALF, 8, mirror), -1.0, RING_CURB_TOP, chamfer=0.08)
    # Centre dashes on r = 245, skipping the crossing (|yaw| < ~3.6 deg).
    r = 245.0
    dash, period = 7.0 / r, 16.0 / r
    a = math.radians(3.6)
    while a + dash < HALF - 0.004:
        for s in (-1, 1):
            lo, hi = (a, a + dash) if s > 0 else (-a - dash, -a)
            slab(dashes, sector_outline(r - 0.55, r + 0.55, lo, hi, 2), -0.1, 0.04, chamfer=0.02)
        a += period
    # Zebra crossing over the junction (stripes run radially), top +0.05.
    for x in (-9.0, -5.4, -1.8, 1.8, 5.4, 9.0):
        box(zebra, (x, -0.025, 245.0), (2.0, 0.15, 20.0))
    return m


# =================================================================================================
# Fixtures
# =================================================================================================


def build_egg_stand():
    """Egg stand: plinth + pedestal + tinted cradle; sign frame on tinted posts with bulbs."""
    m = Model(
        "Hub_EggStand",
        "ground centre; egg pivot at (0, 4.0, 0); Sign front face (z = 2.72) faces -Z; Accent tinted",
        budget=2500,
    )
    base = m.piece("Base", STONE)
    accent = m.piece("Accent", SKY_BLUE, tinted=True)
    frame = m.piece("Frame", CHARCOAL)
    sign = m.piece("Sign", CREAM)
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    block(base, (0.0, 0.4, 0.0), (8.4, 0.8, 8.4), bevel=0.2)
    ring(base, 0.0, 2.3, 0.8, 3.4, 20, chamfer=0.15)
    ring(accent, 1.4, 2.8, 3.4, 4.0, 20, chamfer=0.15)
    ring(accent, 2.3, 3.0, 0.8, 1.3, 20, chamfer=0.1)
    # Posts + sign frame behind and above the egg.
    for x in (-4.6, 4.6):
        block(accent, (x, 6.8, 2.9), (0.8, 12.0, 0.8), bevel=0.12)
    sign_frame(frame, sign, (0.0, 11.4, 2.9), (9.6, 3.6), border=0.4, depth=0.5)
    # Crest above the sign: half disc in the accent colour with a yellow-bulb star.
    crest = [(0.0, 13.2, 2.9)] + [(2.6 * math.cos(a), 13.2 + 2.6 * math.sin(a), 2.9) for a in lin(0.0, math.pi, 10)]
    prism(accent, crest, (0, 0, 1), 0.5)
    for x in lin(-4.2, 4.2, 6):
        bulb(bulbs, (x, 13.3, 2.55))
    return m


def stall(m, wood, wood_dark, awning_a, awning_b, frame, sign, width=14.0):
    """Shared market-stall shell (crate stall, pie stand): counter, posts, back wall, striped
    awning with a scalloped valance, sign board on top. Returns the counter-top height."""
    hw = width / 2
    block(wood, (0.0, 1.7, -2.8), (width - 1.0, 3.4, 2.6), bevel=0.2)  # counter
    # Counter top ends 0.1 inside the front posts' outer faces (never coplanar with them: z-fight).
    block(wood_dark, (0.0, 3.55, -2.9), (width - 0.6, 0.3, 3.0), bevel=0.08)  # counter top
    block(wood, (0.0, 3.5, 4.1), (width - 0.4, 7.0, 0.5), bevel=0.12)  # back wall
    for x in (-hw + 0.6, hw - 0.6):
        block(wood, (x, 4.8, -3.9), (0.8, 9.6, 0.8), bevel=0.12)
        block(wood, (x, 5.4, 3.9), (0.8, 10.8, 0.8), bevel=0.12)
    # Awning: slanted stripes from the front (y 9.6) to the back (y 10.8).
    stripes = 10
    sw = (width + 0.4) / stripes
    pitch = math.degrees(math.atan2(1.2, 9.4))
    for i in range(stripes):
        x = -(width + 0.4) / 2 + sw * (i + 0.5)
        target = awning_a if i % 2 == 0 else awning_b
        block(target, (x, 10.2, -0.3), (sw, 0.3, 9.6), bevel=0.06, rot=rot_x(-pitch))
        # Scalloped valance (half discs hanging under the front edge).
        half = [(x + sw / 2 * math.cos(a), 9.55 + sw / 2 * math.sin(a) * 0.9, -5.05) for a in lin(math.pi, TAU, 6)]
        prism(target, half, (0, 0, 1), 0.2)
    # Sign on two short posts above the awning front.
    for x in (-3.8, 3.8):
        block(frame, (x, 10.6, -4.3), (0.4, 1.6, 0.4), bevel=0.06)
    sign_frame(frame, sign, (0.0, 12.6, -4.3), (10.0, 2.8), border=0.35, depth=0.45)
    return 3.7


def build_crate_stall():
    """Supply-crate market stall: red/white awning, stacked wooden crates with glowing marks."""
    m = Model(
        "Hub_CrateStall",
        "ground centre, front -Z; showcase crate pivot at (0, 3.7, -2.9); Sign front at z = -4.46",
        budget=3000,
    )
    wood = m.piece("Wood", WOOD)
    wood_dark = m.piece("WoodDark", WOOD_DARK)
    awning_a = m.piece("AwningA", TOY_RED)
    awning_b = m.piece("AwningB", WHITE)
    frame = m.piece("Frame", CHARCOAL)
    sign = m.piece("Sign", CREAM)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    stall(m, wood, wood_dark, awning_a, awning_b, frame, sign)
    # Crates behind the counter (dark X braces on the fronts) + glowing trefoils on two of them.
    crates = [(-4.2, 1.3, 1.9), (-1.4, 1.3, 1.9), (-2.8, 3.9, 1.9), (3.6, 1.3, 2.0), (3.6, 3.9, 2.0)]
    for i, (x, y, z) in enumerate(crates):
        block(wood, (x, y, z), (2.6, 2.6, 2.6), bevel=0.15)
        f = z - 1.32
        bar(wood_dark, (x - 1.0, y - 1.0, f), (x + 1.0, y + 1.0, f), 0.3)
        bar(wood_dark, (x - 1.0, y + 1.0, f), (x + 1.0, y - 1.0, f), 0.3)
        if i in (2, 4):
            trefoil(glow, (x, y, f - 0.2), 0.8, 0.12, normal=(0, 0, -1))
    return m


def build_lucky_wheel_stage():
    """Round purple stage, wheel stand + halo of bulbs, pointer and sign (wheel is separate)."""
    m = Model(
        "Hub_LuckyWheelStage",
        "ground centre, front -Z; wheel pivot (Hub_LuckyWheel) at (0, 13, 0); Sign front at z = 0.12",
        budget=3000,
    )
    stage = m.piece("Stage", PURPLE)
    top = m.piece("StageTop", YELLOW)
    frame = m.piece("Frame", WHITE)
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    pointer = m.piece("Pointer", TOY_RED)
    sign = m.piece("Sign", CREAM)
    ring(stage, 0.0, 10.0, 0.0, 1.6, 28, chamfer=0.22)
    ring(top, 0.0, 9.4, 1.6, 1.8, 28, chamfer=0.08)
    block(stage, (0.0, 0.3, -11.3), (7.0, 0.6, 1.8), bevel=0.12)
    block(stage, (0.0, 0.6, -9.9), (7.0, 1.2, 1.6), bevel=0.12)
    # Posts + axle behind the wheel, halo ring around it.
    for x in (-9.0, 9.0):
        block(frame, (x, 7.9, 1.2), (1.2, 12.2, 1.2), bevel=0.15)
    cylinder(frame, (-9.0, 13.0, 1.2), (9.0, 13.0, 1.2), 0.45, segments=10)
    ring_tube(frame, (0.0, 13.0, 0.3), 8.6, 0.8, 0.8, segments=32, axis="Z")
    for i in range(16):
        a = TAU * i / 16
        bulb(bulbs, (8.6 * math.cos(a), 13.0 + 8.6 * math.sin(a), -0.25), radius=0.36)
    # Pointer at the top of the wheel (tip points down at y = 20.6).
    prism(pointer, [(-1.1, 22.5, -0.9), (1.1, 22.5, -0.9), (0.0, 20.55, -0.9)], (0, 0, 1), 0.6)
    ellipsoid(pointer, (0.0, 22.6, -0.9), (0.6, 0.6, 0.45), rings=4, segments=8)
    # Sign above the halo on two short posts.
    for x in (-4.0, 4.0):
        block(frame, (x, 22.9, 0.3), (0.5, 1.8, 0.5), bevel=0.08)
    sign_frame(frame, sign, (0.0, 25.4, 0.3), (12.0, 3.6), border=0.4, depth=0.5)
    return m


def build_lucky_wheel():
    """The spinnable wheel: 8 coloured slices, white rim, pegs and hub. Spin about local Z."""
    m = Model("Hub_LuckyWheel", "axle centre; wheel faces -Z; spin = rotate about the local Z axis", budget=2000)
    colours = (("SliceRed", TOY_RED), ("SliceYellow", YELLOW), ("SliceBlue", SKY_BLUE), ("SliceGreen", LIME))
    slices = [m.piece(name, colour) for name, colour in colours]
    rim = m.piece("Rim", WHITE)
    for k in range(8):
        a0, a1 = TAU * k / 8, TAU * (k + 1) / 8
        pts = [(0.0, 0.0, 0.0)] + [(7.3 * math.cos(a), 7.3 * math.sin(a), 0.0) for a in lin(a0, a1, 6)]
        prism(slices[k % 4], pts, (0, 0, 1), 0.8)
        # White divider line on the front face.
        bar(rim, (1.3 * math.cos(a0), 1.3 * math.sin(a0), -0.45), (7.1 * math.cos(a0), 7.1 * math.sin(a0), -0.45), 0.24)
    ring_tube(rim, (0.0, 0.0, 0.0), 7.5, 0.7, 1.1, segments=32, axis="Z")
    cylinder(rim, (0.0, 0.0, -0.75), (0.0, 0.0, 0.7), 1.4, segments=14)
    for k in range(16):
        a = TAU * (k + 0.5) / 16
        cylinder(rim, (6.9 * math.cos(a), 6.9 * math.sin(a), -0.4), (6.9 * math.cos(a), 6.9 * math.sin(a), -1.0), 0.18, segments=6)
    return m


def build_group_chest():
    """Treasure chest on a purple podium with gold bands, spilling gems; sign behind."""
    m = Model(
        "Hub_GroupChest",
        "ground centre, front -Z; lid hinge (Hub_GroupChestLid pivot) at (0, 4.8, 2.3); Sign front z = 3.44",
        budget=2500,
    )
    podium = m.piece("Podium", PURPLE)
    gold = m.piece("Gold", YELLOW)
    wood = m.piece("Wood", WOOD)
    dark = m.piece("Dark", CHARCOAL)
    gems = m.piece("Gems", GEM, material="Neon")
    sign = m.piece("Sign", CREAM)
    ring(podium, 0.0, 5.6, 0.0, 1.2, 24, chamfer=0.2)
    ring(gold, 5.5, 6.0, 0.0, 1.35, 24, chamfer=0.1)
    block(wood, (0.0, 3.0, 0.0), (7.0, 3.6, 4.6), bevel=0.25)
    for x in (-2.4, 2.4):
        block(gold, (x, 3.0, 0.0), (0.6, 3.75, 4.75), bevel=0.08)
    block(gold, (0.0, 3.7, -2.42), (1.4, 1.6, 0.3), bevel=0.06)
    block(dark, (0.0, 3.55, -2.6), (0.3, 0.7, 0.12), bevel=0.03)

    def gem(c, s):
        cx, cy, cz = c
        pts = [(cx + s, cy, cz), (cx, cy, cz + s), (cx - s, cy, cz), (cx, cy, cz - s)]
        prism(gems, pts, (0, 1, 0), s * 0.9)  # flat square gem, rotated 45 deg (cheap "diamond")
        ellipsoid(gems, (cx, cy + s * 0.45, cz), (s * 0.5, s * 0.5, s * 0.5), rings=3, segments=4)

    for c, s in (((-1.6, 4.9, 0.4), 0.7), ((0.4, 5.0, -0.5), 0.8), ((1.9, 4.85, 0.6), 0.6), ((-2.8, 1.45, -3.6), 0.55), ((2.6, 1.4, -4.0), 0.5)):
        gem(c, s)
    # Sign posts end inside the frame's side bars; x 3.38 keeps their outer faces (3.605) off the
    # panel's side faces (3.625), which they would otherwise share (z-fight audit, R18).
    for x in (-3.38, 3.38):
        block(dark, (x, 5.2, 3.6), (0.45, 8.0, 0.45), bevel=0.06)
    sign_frame(dark, sign, (0.0, 9.3, 3.6), (7.6, 2.4), border=0.35, depth=0.45)
    return m


def build_group_chest_lid():
    """Half-round chest lid; pivot = hinge (back top edge). Closed pose; open by rotating about X."""
    m = Model("Hub_GroupChestLid", "hinge at the lid's back bottom edge; closed pose; rotate about local X to open", budget=800)
    wood = m.piece("Wood", WOOD)
    gold = m.piece("Gold", YELLOW)

    def half_disc(piece, r, x, thickness):
        pts = [(x, r * math.sin(a), -2.3 + r * math.cos(a)) for a in lin(0.0, math.pi, 10)]
        prism(piece, pts, (1, 0, 0), thickness)

    half_disc(wood, 2.3, 0.0, 7.0)
    for x in (-2.4, 2.4):
        half_disc(gold, 2.42, x, 0.6)
    block(gold, (0.0, 0.5, -4.66), (1.2, 1.1, 0.3), bevel=0.06)
    return m


def build_codes_board():
    """Codes board: slate Screen in a blue frame on white posts, a giant golden key on top."""
    m = Model("Hub_CodesBoard", "ground centre; Screen front face (13 x 8.2) at z = -0.25 faces -Z", budget=1500)
    posts = m.piece("Posts", WHITE)
    frame = m.piece("Frame", SKY_BLUE)
    screen = m.piece("Screen", SLATE)
    key = m.piece("Key", YELLOW)
    for x in (-5.8, 5.8):
        block(posts, (x, 3.0, 0.35), (0.9, 6.0, 0.9), bevel=0.12)
    cy = 9.6
    block(screen, (0.0, cy, 0.0), (13.0, 8.2, 0.5), bevel=0.05)
    for y in (cy - 4.4, cy + 4.4):
        block(frame, (0.0, y, 0.0), (14.4, 0.8, 0.8), bevel=0.12)
    for x in (-6.8, 6.8):
        block(frame, (x, cy, 0.0), (0.8, 9.6, 0.8), bevel=0.12)
    # Giant key standing on the frame top (bow left, teeth right).
    ring_tube(key, (-3.6, 16.0, 0.0), 1.3, 0.7, 0.6, segments=14, axis="Z")
    block(key, (0.7, 16.0, 0.0), (7.2, 0.7, 0.6), bevel=0.1)
    for x in (3.0, 4.0):
        block(key, (x, 15.2, 0.0), (0.6, 1.0, 0.6), bevel=0.08)
    return m


def build_leaderboard():
    """Tall leaderboard: slate Screen in a tinted frame, white plinth/posts, golden trophy."""
    m = Model("Hub_Leaderboard", "ground centre; Screen front face (12.8 x 17.8) at z = -0.25 faces -Z; Frame tinted", budget=2500)
    base = m.piece("Base", STONE)
    frame = m.piece("Frame", LIME, tinted=True)
    screen = m.piece("Screen", SLATE)
    trophy = m.piece("Trophy", YELLOW)
    block(base, (0.0, 0.5, 0.2), (16.0, 1.0, 3.6), bevel=0.2)
    for x in (-6.3, 6.3):
        block(base, (x, 2.3, 0.4), (1.0, 3.0, 1.0), bevel=0.12)
    cy = 12.9
    block(screen, (0.0, cy, 0.0), (12.8, 17.8, 0.5), bevel=0.05)
    for y in (cy - 9.3, cy + 9.3):
        block(frame, (0.0, y, 0.0), (14.4, 0.8, 0.8), bevel=0.12)
    for x in (-6.8, 6.8):
        block(frame, (x, cy, 0.0), (0.8, 19.4, 0.8), bevel=0.12)
    crest = [(0.0, 22.6, 0.0)] + [(4.0 * math.cos(a), 22.6 + 2.6 * math.sin(a), 0.0) for a in lin(0.0, math.pi, 10)]
    prism(frame, crest, (0, 0, 1), 0.7)
    # Trophy cup on the crest.
    revolve(
        trophy,
        [(0.0, 0.0), (1.2, 0.0), (1.2, 0.35), (0.35, 0.6), (0.35, 1.4), (1.5, 1.9), (1.6, 3.4), (1.4, 3.5), (0.0, 3.0)],
        center=(0.0, 24.6, 0.0),
        segments=14,
    )
    for s in (-1, 1):
        ring_tube(trophy, (s * 1.7, 27.0, 0.0), 0.55, 0.25, 0.3, segments=8, axis="Z")
    return m


# =================================================================================================
# Street furniture
# =================================================================================================


def build_bench():
    """Park bench: wooden seat + back slats on charcoal side frames. Sitter faces -Z; seat y 1.8."""
    m = Model("Hub_Bench", "ground centre; sitter faces -Z; seat top y = 1.8", budget=700)
    wood = m.piece("Wood", WOOD)
    legs = m.piece("Legs", CHARCOAL)
    for z in (-0.65, 0.0, 0.65):
        block(wood, (0.0, 1.65, z), (6.0, 0.3, 0.55), bevel=0.08)
    for y in (2.6, 3.4):
        block(wood, (0.0, y, 1.05), (6.0, 0.55, 0.25), bevel=0.06)
    for x in (-2.6, 2.6):
        block(legs, (x, 0.75, -0.55), (0.35, 1.5, 0.35), bevel=0.05)
        block(legs, (x, 1.9, 0.95), (0.35, 3.8, 0.35), bevel=0.05)
        block(legs, (x, 1.4, 0.2), (0.35, 0.3, 1.9), bevel=0.05)
    return m


def build_lamp():
    """Hub street lamp (14 tall): dark pole, yellow collar + cap, warm glowing globe at y 12.2."""
    m = Model("Hub_Lamp", "ground centre; globe centre (PointLight anchor) at y = 12.2", budget=800)
    pole = m.piece("Pole", DARK_STEEL)
    cap = m.piece("Cap", YELLOW)
    globe = m.piece("Globe", LAMP_WARM, material="Neon")
    block(pole, (0.0, 0.4, 0.0), (1.7, 0.8, 1.7), bevel=0.15)
    cylinder(pole, (0.0, 0.8, 0.0), (0.0, 11.0, 0.0), 0.3, segments=10)
    ring(cap, 0.0, 0.75, 10.8, 11.2, 12, chamfer=0.08)
    ring(cap, 0.0, 0.55, 2.0, 2.4, 12, chamfer=0.08)
    ellipsoid(globe, (0.0, 12.2, 0.0), (1.15, 1.25, 1.15), rings=6, segments=12)
    revolve(cap, [(0.0, 0.0), (1.25, 0.0), (0.9, 0.5), (0.0, 0.7)], center=(0.0, 13.2, 0.0), segments=12)
    return m


def build_tree():
    """Round toy tree (~15 tall): brown trunk, three chunky leaf blobs."""
    m = Model("Hub_Tree", "ground centre; canopy radius ~5, top y ~ 13.5", budget=800)
    trunk = m.piece("Trunk", BROWN)
    leaves = m.piece("Leaves", LEAF)
    cylinder(trunk, (0.0, 0.0, 0.0), (0.0, 7.5, 0.0), 0.8, segments=8, radius_b=0.6)
    ellipsoid(leaves, (0.0, 9.6, 0.0), (4.6, 3.9, 4.6), rings=6, segments=10)
    ellipsoid(leaves, (-2.3, 8.0, 1.2), (2.9, 2.5, 2.9), rings=5, segments=8)
    ellipsoid(leaves, (2.2, 8.3, -1.0), (3.0, 2.6, 3.0), rings=5, segments=8)
    return m


def build_planter():
    """Square white planter with a round bush and pink/yellow block flowers."""
    m = Model("Hub_Planter", "ground centre; 5.4 x 5.4 footprint, rim top y = 1.4", budget=800)
    box_p = m.piece("Box", STONE)
    leaves = m.piece("Leaves", LEAF)
    flowers = m.piece("Flowers", PINK)
    dots = m.piece("Dots", YELLOW)
    block(box_p, (0.0, 0.7, 0.0), (5.4, 1.4, 5.4), bevel=0.2)
    ellipsoid(leaves, (0.0, 1.9, 0.0), (2.3, 1.5, 2.3), rings=5, segments=8)
    for i in range(6):
        x, z = polar(1.9, TAU * i / 6 + 0.3)
        block(flowers, (x, 2.5 + 0.25 * (i % 2), z), (0.8, 0.5, 0.8), bevel=0.1)
        block(dots, (x, 2.8 + 0.25 * (i % 2), z), (0.36, 0.2, 0.36), bevel=0.05)
    return m


# =================================================================================================
# Lobby wayfinding (owner R13): "SELL NUKES" title sign, numbered plot gates, digit models
# =================================================================================================

# 5 x 7 pixel toy font (rows top -> bottom, "#" = stud block). Only the glyphs the hub needs.
GLYPHS = {
    "S": (".###.", "#...#", "#....", ".###.", "....#", "#...#", ".###."),
    "E": ("#####", "#....", "#....", "####.", "#....", "#....", "#####"),
    "L": ("#....", "#....", "#....", "#....", "#....", "#....", "#####"),
    "N": ("#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"),
    "U": ("#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
    "K": ("#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"),
    "1": ("..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."),
    "2": (".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"),
    "3": ("####.", "....#", "....#", ".###.", "....#", "....#", "####."),
    "4": ("...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."),
    "5": ("#####", "#....", "####.", "....#", "....#", "#...#", ".###."),
    "6": ("..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."),
    "7": ("#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."),
    "8": (".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."),
}


def glyph_rects(char):
    """
    Greedy rectangle cover of a glyph bitmap: horizontal runs per row, then runs with the same
    span in consecutive rows merge downward. Returns [(col0, row0, cols, rows)] (row 0 = top).
    Fewer rectangles = fewer triangles (most glyphs collapse to 4-8 boxes).
    """
    rows = GLYPHS[char]
    runs = []
    for r, line in enumerate(rows):
        c = 0
        while c < len(line):
            if line[c] == "#":
                start = c
                while c < len(line) and line[c] == "#":
                    c += 1
                runs.append((start, r, c - start))
            else:
                c += 1
    rects = []
    for start, r, width in runs:
        for rect in rects:
            if rect[0] == start and rect[2] == width and rect[1] + rect[3] == r:
                rect[3] += 1
                break
        else:
            rects.append([start, r, width, 1])
    return [tuple(rect) for rect in rects]


def voxel_text(piece, text, centre_x, top_y, z, pixel, depth, facing=-1, gap=1):
    """
    Raised pixel-font text in the XY plane. facing = -1 reads correctly from the -Z side (model
    front), +1 from the +Z side (text runs toward +X). Each glyph is 5 x 7 pixels, `gap` pixels apart.
    Example: voxel_text(letters, "SELL", 0, 30, -1.1, 1.1, 1.0)
    """
    width = (len(text) * (5 + gap) - gap) * pixel
    for i, ch in enumerate(text):
        if ch == " ":
            continue
        for col, row, cols, rows in glyph_rects(ch):
            u = i * (5 + gap) * pixel + (col + cols / 2) * pixel - width / 2  # distance along the line
            x = centre_x - u if facing < 0 else centre_x + u
            y = top_y - (row + rows / 2) * pixel
            box(piece, (x, y, z), (cols * pixel, rows * pixel, depth))


def build_title_sign():
    """Big lobby sign 'SELL' / 'NUKES' (pixel stud letters, both faces) on two posts, bulbs, nuke."""
    m = Model("Hub_TitleSign", "ground centre; board y 12.5-32.5 between posts at x = +-20.2; letters on both faces", budget=4000)
    posts = m.piece("Posts", STONE)
    board = m.piece("Board", DEEP_BLUE)
    frame = m.piece("Frame", TOY_RED)
    sell = m.piece("LettersSell", YELLOW)
    nukes = m.piece("LettersNukes", LIME)
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    fins = m.piece("Fins", CHARCOAL)
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    for x in (-20.2, 20.2):
        block(posts, (x, 16.6, 0.0), (2.2, 33.2, 2.2), bevel=0.25)
        block(fins, (x, 0.6, 0.0), (3.4, 1.2, 3.4), bevel=0.2)
    # Board edges end inside the frame bars (no shared top / side planes with the frame: z-fight).
    block(board, (0.0, 22.5, 0.0), (37.6, 19.6, 1.2), bevel=0.15)
    for y in (12.95, 32.05):
        block(frame, (0.0, y, 0.0), (39.0, 0.9, 1.6), bevel=0.15)
    for x in (-19.05, 19.05):
        block(frame, (x, 22.5, 0.0), (0.9, 20.0, 1.6), bevel=0.15)
    pixel = 1.1
    for facing, z in ((-1, -1.1), (1, 1.1)):
        voxel_text(sell, "SELL", 0.0, 31.0, z, pixel, 1.0, facing)
        voxel_text(nukes, "NUKES", 0.0, 22.3, z, pixel, 1.0, facing)
    for x in lin(-17.5, 17.5, 10):
        for z in (-0.95, 0.95):
            bulb(bulbs, (x, 32.85, z), radius=0.36)
    nuke_body(frame, posts, fins, core, base=(0.0, 32.5, 0.0), length=8.0, radius=1.8, segments=14)
    return m


def build_plot_gate():
    """Numbered gate over each avenue's outer end (the digit models sit on the tinted badge)."""
    m = Model(
        "Hub_PlotGate",
        "ground centre on the avenue axis; pillars at x = +-14.5; badge centre (digit anchor) at (0, 20.4, 0)",
        budget=2000,
    )
    pillar = m.piece("Pillar", STONE)
    base = m.piece("Base", CHARCOAL)
    accent = m.piece("Accent", SKY_BLUE, tinted=True)
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    for x in (-14.5, 14.5):
        block(base, (x, 0.6, 0.0), (4.0, 1.2, 4.0), bevel=0.2)
        block(pillar, (x, 8.6, 0.0), (3.0, 14.8, 3.0), bevel=0.25)
        block(accent, (x, 6.0, 0.0), (3.4, 0.7, 3.4), bevel=0.12)
        block(accent, (x, 16.4, 0.0), (3.8, 1.0, 3.8), bevel=0.15)
    block(pillar, (0.0, 15.6, 0.0), (32.0, 2.8, 2.2), bevel=0.2)
    # Round tinted badge on the beam (digits go on both faces), white rim.
    revolve(accent, [(0.0, -0.6), (5.0, -0.6), (5.3, 0.0), (5.0, 0.6), (0.0, 0.6)], center=(0.0, 20.4, 0.0), segments=20, rot=rot_x(90))
    ring_tube(pillar, (0.0, 20.4, 0.0), 5.45, 0.6, 1.5, segments=20, axis="Z")
    for x in lin(-12.0, 12.0, 8):
        if abs(x) > 5.0:
            for z in (-1.0, 1.0):
                bulb(bulbs, (x, 17.25, z), radius=0.34)
    return m


def _digit_builder(char):
    def build():
        m = Model(
            f"Hub_Digit{char}",
            "bottom centre of the glyph, reads from -Z; 4.5 wide x 6.3 tall x 0.8 deep; Digit tinted",
            budget=600,
        )
        voxel_text(m.piece("Digit", WHITE, tinted=True), char, 0.0, 6.3, 0.0, 0.9, 0.8)
        return m

    return build


BUILDERS = {
    "Hub_Avenue": build_avenue,
    "Hub_DistrictWedge": build_district_wedge,
    "Hub_RingRoadArc": build_ring_road_arc,
    "Hub_EggStand": build_egg_stand,
    "Hub_CrateStall": build_crate_stall,
    "Hub_LuckyWheelStage": build_lucky_wheel_stage,
    "Hub_LuckyWheel": build_lucky_wheel,
    "Hub_GroupChest": build_group_chest,
    "Hub_GroupChestLid": build_group_chest_lid,
    "Hub_CodesBoard": build_codes_board,
    "Hub_Leaderboard": build_leaderboard,
    "Hub_Bench": build_bench,
    "Hub_Lamp": build_lamp,
    "Hub_Tree": build_tree,
    "Hub_Planter": build_planter,
    "Hub_TitleSign": build_title_sign,
    "Hub_PlotGate": build_plot_gate,
}
BUILDERS.update({f"Hub_Digit{n}": _digit_builder(str(n)) for n in range(1, 9)})
