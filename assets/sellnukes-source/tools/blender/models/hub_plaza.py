"""
hub_plaza.py — the lobby centre (owner R55, L1-lobby 2026-10-30: "I think the center lobby looks
like shit"). Replaces B8e's flat grey centre disc + rocket fountain with a layered stud-toy plaza
built around a giant waving Nukey statue on a toy-nuke fountain.

World layout (hub centre at the origin, ground top y = 0; yaw from +Z toward +X; HubLayout.luau
places every model and mirrors the constants below — change both together):

    r  0.0 - 26.6   Hub_Monument      fountain: outer pool (8 toy-nuke spouts on the rim spraying
                                      water arcs), middle bowl with a water curtain, square plinth
                                      with "NUKEY" plaques. Hub_NukeyStatue stands on the plinth
                                      (top y = PLINTH_TOP), Hub_CoinHalo spins above his head.
    r 27.6 - 38.6   Hub_CenterPlaza   lime border, 24 yellow / white "fountain walk" tiles, lime border
    r 38.6 - 80.5   Hub_PlazaSpoke x8 one plot-coloured path per plot (tinted), white edging,
                                      white chevrons (its R55 Hub_TeleportPad at r 62 was removed, R134)
                    Hub_PlazaGarden x7 raised garden bed in every wedge between two spokes except the
                                      spawn wedge (wedge 0, yaw 22.5): cream wall, lime coping, grass,
                                      bushes, flowers, a topiary tree
                    spawn wedge       Hub_CenterPlaza's yellow / white welcome carpet from the spawn
                                      pad (r 44) out to the rim, lined with banners + planters
    r 80.5 - 86.5   Hub_CenterPlaza   lime rim with yellow diamond inlays (covers the step to the
                                      avenues / districts)
    furniture       Hub_BannerPole (waving banner), Hub_Bunting (spoke-mouth gateway: two lamp posts +
                    a pennant string), Hub_Coin (floating spinning coin), Hub_Bench

Layers (z-fight rule, docs/areas-art.md — no two overlapping faces share a plane, no curved seam at
one height): dais 0.06, fountain-walk tiles / rim 0.12, spoke paths / welcome carpet 0.15,
lime borders / rim inlays / tile inlays 0.18, spoke edging + chevrons / carpet borders 0.21.

Ambient motion (WorldFxConfig rows, matched by piece name; client-side, budgeted):
    Ripple    water rings bob             Wave      Nukey's waving arm (turns about the shoulder)
    Streamer  banners twist in the wind   Pennant   bunting strings swing
    Twirl     pad-sign stars turn slowly  Whirl     floating coins spin    Carousel  coin halo orbits
A rotating piece turns about its bounding-box centre (its MeshPart CFrame), so `balance_about`
mirrors a piece's box around the real joint with two tiny cubes hidden inside other geometry.

Budgets: the rebuilt B8e keys keep their original budgets (centre floor 3,000, fountain 6,000 incl.
its 8 low-poly spouts, teleport pad 1,500, spawn pad 800); new keys: garden 3,000, statue 6,000
(hero), small props <= 1,500. Pieces are merged wherever colours
allow (garden 6, pad 5, banner 3, gateway 6) because the whole lobby is always streamed in.
"""

import math

from mathutils import Vector

from models.area01 import block_text, text_cells
from models.hub import (
    HALF,
    STONE,
    TAU,
    WATER,
    arc_blocks,
    chevron_outline,
    lin,
    polar,
    ring,
    rotated,
    sector_outline,
    slab,
    star_outline,
    strip_outline,
    wedge_corner,
    wedge_outline,
)
from snkit.core import (
    BROWN,
    CHARCOAL,
    CREAM,
    DEEP_BLUE,
    GRASS,
    LEAF,
    LIME,
    Model,
    PINK,
    SKY_BLUE,
    TOY_RED,
    WHITE,
    YELLOW,
    br,
    rb,
)
from snkit.kit import block, nuke_body, trefoil
from snkit.shapes import bar, box, cylinder, ellipsoid, extrude_outline, loft, prism, revolve, ring_tube, rot_x, rot_y

# ---- Plaza dimensions (HubLayout.luau mirrors these; change both together) -----------------------
FOUNTAIN_R = 26.6  # outer edge of the fountain's yellow cap
WALK_IN_R = 28.4  # fountain-walk tile ring
WALK_OUT_R = 37.6
BORDER_W = 0.8  # lime border rings either side of the tile ring
SPOKE_IN_R = WALK_OUT_R + BORDER_W  # 38.4: spoke paths start at the outer lime border
RIM_IN_R = 80.5  # lime rim ring (covers the plaza / avenue / district step at r 84)
RIM_OUT_R = 86.5
SPOKE_HALF = 8.0  # tinted path half-width
EDGE_W = 1.0  # white edging, |x| 8..9
GARDEN_R0 = 48.0  # garden beds between the spokes
GARDEN_R1 = 77.0
GARDEN_OFFSET = 12.5  # garden edge distance from each spoke axis (3.5-stud walkway beside the path)
GARDEN_TOP = 1.3  # grass top (props stand here)
COPING_TOP = 1.55
SPAWN_YAW = math.radians(22.5)  # spawn wedge bisector (HubLayout SPAWN_YAW)
SPAWN_R = 44.0  # spawn pad centre radius (HubLayout SPAWN_R)
CARPET_HALF = 5.0  # welcome carpet half-width

# Fountain.
POOL_TOP = 1.7  # outer pool water surface (players wade at this height)
BOWL_R = 12.6  # middle bowl outer radius
BOWL_WATER = 7.25  # bowl water surface
PLINTH_HALF = 6.0  # square plinth half-size
PLINTH_TOP = 12.2  # plinth top = Hub_NukeyStatue pivot height
SPOUT_R = 24.4  # toy-nuke spouts on the cap
SPOUT_LEN = 5.6
CAP_TOP = 2.9
LAND_R = 16.0  # where the spout arcs land in the pool (landing ripples clear the r 14 ring)

# Statue (Nukey scaled from the A8_MascotNukey proportions).
NUKEY_SCALE = 1.75
NUKEY_TOP = 18.0 * NUKEY_SCALE  # tip height above the plinth (31.5)

# Palette additions (the stud map darkens every colour ~10 %).
PAVE = (246, 241, 230)  # warm white dais
GOLD = (255, 198, 40)  # coins
RIPPLE = (214, 246, 255)
FLOOR_BLUE = (40, 120, 210)


# =================================================================================================
# Helpers
# =================================================================================================


def balance_about(piece, pivot, axes=(0, 1), free=(0.0, 0.0, 0.0), hide_check=None):
    """
    Adds ONE tiny cube so the piece's bounding-box centre lands on `pivot` along `axes` (Roblox
    space, 0 = X, 1 = Y, 2 = Z). WorldFxController turns a moving piece about its MeshPart CFrame,
    which Roblox puts at the mesh's bounding-box centre, so a waving arm must have its box mirrored
    around the shoulder. Only the axes perpendicular to the turn axis matter (an arm waving about
    Z needs X and Y balanced); the cube takes `free` on the other axes. Per balanced axis the cube
    sits at the mirror of the far end (2 * pivot - far), which extends the box on the near side.
    `hide_check(point) -> bool` asserts the cube lands inside other geometry (never visible).

    Example: balance_about(arm, (5.4, 16.5, 0.0), axes=(0, 1), hide_check=inside_body)
    """
    pts = [br(v.co) for v in piece.bm.verts]
    lo = [min(p[i] for p in pts) for i in range(3)]
    hi = [max(p[i] for p in pts) for i in range(3)]
    cube = list(free)
    for i in axes:
        mid = (lo[i] + hi[i]) / 2
        cube[i] = 2 * pivot[i] - (lo[i] if pivot[i] > mid else hi[i])
    if hide_check is not None and not hide_check(cube):
        raise ValueError(f"balance_about({piece.name}): balance cube at {cube} would be visible")
    box(piece, tuple(cube), (0.04, 0.04, 0.04))


def yaw_new_verts(piece, start, degrees):
    """Rotates every vertex added to `piece` since vertex index `start` about the Y axis."""
    rot = rot_y(degrees)
    piece.bm.verts.ensure_lookup_table()
    for v in piece.bm.verts[start:]:
        v.co = rb(tuple(rot @ Vector(br(v.co))))


def band_outline(x0, x1, r0, r1, segments=4):
    """Straight strip x0 <= x <= x1 along +Z whose ends follow the circles r0 / r1 (no inset)."""
    outer = [(x, math.sqrt(r1 * r1 - x * x)) for x in lin(x0, x1, segments)]
    inner = [(x, math.sqrt(r0 * r0 - x * x)) for x in lin(x1, x0, segments)]
    return outer + inner


def diamond(cx, cz, w, h, spin=0.0):
    """Flat rhombus outline (x, z) centred at (cx, cz), rotated by `spin` radians."""
    pts = [(0.0, h / 2), (w / 2, 0.0), (0.0, -h / 2), (-w / 2, 0.0)]
    c, s = math.cos(spin), math.sin(spin)
    return [(cx + x * c + z * s, cz - x * s + z * c) for x, z in pts]


def coin(piece, center, radius, depth, normal_yaw=0.0, segments=16):
    """
    Chunky toy coin standing on its edge: disc + raised rim + raised star on BOTH faces (one
    colour; the relief reads through lighting). Faces look along +-Z rotated by `normal_yaw` deg.
    """
    rot = rot_y(normal_yaw) @ rot_x(90)
    revolve(
        piece,
        [(0.0, -depth / 2), (radius * 0.86, -depth / 2), (radius, -depth * 0.32), (radius, depth * 0.32), (radius * 0.86, depth / 2), (0.0, depth / 2)],
        center=center,
        segments=segments,
        rot=rot,
    )
    # Star relief on both faces (5 points, tip up).
    star = star_outline(0.0, 0.0, radius * 0.55, radius * 0.24, 5)
    yaw_rot = rot_y(normal_yaw)
    for side in (-1, 1):
        pts = []
        for x, z in star:
            # The star lies in the coin's face plane (local XY), pushed out along the face normal.
            local = Vector((x, z, side * (depth / 2 + 0.05)))
            p = yaw_rot @ local
            pts.append((center[0] + p.x, center[1] + p.y, center[2] + p.z))
        normal = yaw_rot @ Vector((0.0, 0.0, 1.0))
        prism(piece, pts, tuple(normal), 0.14)


def tube(piece, points, radius, sides=6, radius_end=None):
    """Smooth closed tube (loft of circles) through `points` (Roblox space), optional taper."""
    r_end = radius if radius_end is None else radius_end
    sections = []
    count = len(points)
    for i, p in enumerate(points):
        a = Vector(points[max(i - 1, 0)])
        b = Vector(points[min(i + 1, count - 1)])
        t = (b - a).normalized()
        up = Vector((0, 1, 0)) if abs(t.y) < 0.95 else Vector((1, 0, 0))
        x = up.cross(t).normalized()
        y = t.cross(x)
        r = radius + (r_end - radius) * i / (count - 1)
        c = Vector(p)
        sections.append([tuple(c + (x * math.cos(TAU * k / sides) + y * math.sin(TAU * k / sides)) * r) for k in range(sides)])
    loft(piece, sections)


# =================================================================================================
# Plaza floor
# =================================================================================================


def build_center_plaza():
    """
    Dais r 0-84 (warm white), fountain-walk tile ring with lime borders, the spawn wedge's welcome
    carpet and the lime rim with yellow diamond inlays. Spoke paths are Hub_PlazaSpoke (tinted).
    """
    m = Model("Hub_CenterPlaza", "world origin (hub centre) on the ground; dais r = 84 (top 0.06), rim r 80.5-86.5", budget=3000)
    paving = m.piece("Paving", PAVE)
    tile_a = m.piece("TileA", YELLOW)
    tile_b = m.piece("TileB", WHITE)
    lime = m.piece("Lime", LIME)
    inlay = m.piece("Inlay", WHITE)
    # Dais: top +0.06 (meets the avenues / districts along a circle; the rim covers the step).
    ring(paving, 0.0, 84.0, -1.0, 0.06, 64, chamfer=0.3)
    # Lime borders either side of the fountain walk (top 0.18).
    ring(lime, WALK_IN_R - BORDER_W, WALK_IN_R, -0.2, 0.18, 40, chamfer=0.0)
    ring(lime, WALK_OUT_R, SPOKE_IN_R, -0.2, 0.18, 48, chamfer=0.0)
    # Fountain walk: 24 tiles alternating yellow / white (top 0.12, radial grout gaps = dais).
    for i in range(24):
        a0 = TAU * i / 24 + 0.006
        a1 = TAU * (i + 1) / 24 - 0.006
        slab(tile_a if i % 2 == 0 else tile_b, sector_outline(WALK_IN_R, WALK_OUT_R, a0, a1, 3), -0.2, 0.12, chamfer=0.0)
        if i % 2 == 0:
            mid = TAU * (i + 0.5) / 24
            cx, cz = polar((WALK_IN_R + WALK_OUT_R) / 2, mid)
            extrude_outline(inlay, diamond(cx, cz, 2.4, 4.2, mid), 0.0, 0.18)
    # Rim: lime ring r 80.5-86.5 (top 0.12) + 24 yellow diamonds (top 0.18).
    ring(lime, RIM_IN_R, RIM_OUT_R, -0.2, 0.12, 64, chamfer=0.0)
    for i in range(24):
        a = TAU * (i + 0.5) / 24
        cx, cz = polar((RIM_IN_R + RIM_OUT_R) / 2, a)
        extrude_outline(tile_a, diamond(cx, cz, 2.6, 3.4, a), 0.0, 0.18)
    # Welcome carpet (spawn wedge, yaw 22.5): yellow / white checker from under the spawn pad
    # (r 53.5 edge) out to the rim, top 0.15; lime border strips (top 0.21) along both sides.
    spin = SPAWN_YAW
    z0, z1 = 52.0, 80.8
    rows = 6
    step = (z1 - z0) / rows
    for r in range(rows):
        for c, (xa, xb) in enumerate(((-CARPET_HALF, 0.0), (0.0, CARPET_HALF))):
            za, zb = z0 + r * step, z0 + (r + 1) * step
            outline = [(xa, za), (xb, za), (xb, zb), (xa, zb)]
            piece = tile_a if (r + c) % 2 == 0 else tile_b
            extrude_outline(piece, rotated(lambda d, o=outline: o, spin)(0.0), -0.2, 0.15)
    for side in (-1, 1):
        xa, xb = sorted((side * CARPET_HALF, side * (CARPET_HALF + 0.8)))
        outline = [(xa, z0), (xb, z0), (xb, z1), (xa, z1)]
        extrude_outline(lime, rotated(lambda d, o=outline: o, spin)(0.0), -0.2, 0.21)
    return m


def build_plaza_spoke():
    """
    One plot's coloured path from the fountain walk (r 38.4) to the rim (r 80.5) along +Z: tinted
    paving (top 0.15), white edging |x| 8..9 and white chevrons (top 0.21) pointing to the plot.
    (The plot's Hub_TeleportPad stood on it at r 62 until owner R134 removed the pads.)
    """
    m = Model("Hub_PlazaSpoke", "world origin; path along +Z from r 38.4 to r 80.5; Path tinted with the plot colour", budget=600)
    path = m.piece("Path", LIME, tinted=True)
    white = m.piece("Edging", WHITE)
    slab(path, strip_outline(SPOKE_IN_R, RIM_IN_R, SPOKE_HALF, 6), -0.2, 0.15, chamfer=0.06)
    for side in (-1, 1):
        x0, x1 = sorted((side * SPOKE_HALF, side * (SPOKE_HALF + EDGE_W)))
        extrude_outline(white, band_outline(x0, x1, SPOKE_IN_R, RIM_IN_R), -0.2, 0.21)
    # Chevrons: two before the pad (pad disc r 5.6 at z 62), two after its sign (posts end z 68.9).
    for z in (44.0, 50.0, 73.0, 78.0):
        extrude_outline(white, chevron_outline(0.0, z, 8.0, 3.6, 1.5), 0.0, 0.21)
    return m


# =================================================================================================
# Garden bed (wedges 1-7)
# =================================================================================================


def garden_outline(inset=0.0):
    """Outline function of the garden bed (wedge between two spokes), inset by `inset` studs."""
    return wedge_outline(GARDEN_R0 + inset, GARDEN_R1 - inset, HALF, GARDEN_OFFSET + inset, 16, 6)


def build_plaza_garden():
    """
    Raised garden bed filling one wedge between two spokes (bisector +Z): cream wall, chunky lime
    coping, grass top (y 1.3), a row of round bushes along the back, pink bloom borders down both
    sides and a two-ball topiary tree (top y 16.8; HubLayout floats a spinning coin over it: the
    "money tree"). The banner pole, bench and coin are separate models.
    """
    m = Model("Hub_PlazaGarden", "world origin; wedge bisector +Z, bed r 48-77, edges 12.5 from the spoke axes; grass top y = 1.3", budget=3000)
    wall = m.piece("BedWall", CREAM)
    coping = m.piece("Coping", LIME)
    grass = m.piece("Grass", GRASS)
    leaves = m.piece("Leaves", LEAF)
    bush = leaves  # bushes + topiary share one leafy piece (one draw)
    trunk = m.piece("Trunk", BROWN)
    flowers = m.piece("Flowers", PINK)
    slab(wall, garden_outline(), -0.1, 0.9, chamfer=0.12)
    slab(grass, garden_outline(0.85), 0.6, GARDEN_TOP, chamfer=0.1)
    # Coping: kerb stones round the bed (centre line 0.45 inside the edge), top 1.55.
    c_off = GARDEN_OFFSET + 0.45
    for r, count in ((GARDEN_R0 + 0.45, 4), (GARDEN_R1 - 0.45, 10)):
        left = wedge_corner(r, HALF, c_off, -1)
        right = wedge_corner(r, HALF, c_off, 1)
        arc_blocks(coping, r, math.atan2(left[0], left[1]), math.atan2(right[0], right[1]), 0.9, 0.85, COPING_TOP, count, bevel=0.12)
    for side in (-1, 1):
        p0 = wedge_corner(GARDEN_R0 + 0.45, HALF, c_off, side)
        p1 = wedge_corner(GARDEN_R1 - 0.45, HALF, c_off, side)
        mid = ((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2)
        block(coping, (mid[0], (0.85 + COPING_TOP) / 2, mid[1]), (0.9, COPING_TOP - 0.85, math.dist(p0, p1) + 0.9), bevel=0.12, rot=rot_y(side * 22.5))
    # Bushes along the back arc (r 73), alternating sizes.
    left = wedge_corner(73.0, HALF, GARDEN_OFFSET + 2.6, -1)
    right = wedge_corner(73.0, HALF, GARDEN_OFFSET + 2.6, 1)
    a0, a1 = math.atan2(left[0], left[1]), math.atan2(right[0], right[1])
    for i, a in enumerate(lin(a0, a1, 6)):
        x, z = polar(73.0, a)
        s = 1.0 if i % 2 == 0 else 0.8
        ellipsoid(bush, (x, GARDEN_TOP + 1.2 * s, z), (2.2 * s, 1.9 * s, 2.2 * s), rings=5, segments=9)
    # Flower borders: round pink blooms down both side edges.
    for side in (-1, 1):
        for i, r in enumerate(lin(52.0, 70.0, 7)):
            x, z = wedge_corner(r, HALF, GARDEN_OFFSET + 2.0, side)
            s_ = 1.0 if i % 2 == 0 else 0.8
            ellipsoid(flowers, (x, GARDEN_TOP + 0.45 * s_, z), (0.75 * s_, 0.6 * s_, 0.75 * s_), rings=3, segments=6)
    # Topiary tree (two leaf balls on a trunk) with a ring of pink blooms round its foot.
    tz = 65.5
    cylinder(trunk, (0.0, GARDEN_TOP - 0.2, tz), (0.0, 9.2, tz), 0.75, segments=8, radius_b=0.55)
    ellipsoid(leaves, (0.0, 10.6, tz), (3.9, 3.4, 3.9), rings=7, segments=12)
    ellipsoid(leaves, (0.0, 14.6, tz), (2.5, 2.2, 2.5), rings=6, segments=10)
    for i in range(8):
        x, z = polar(1.9, TAU * i / 8)
        ellipsoid(flowers, (x, GARDEN_TOP + 0.35, tz + z), (0.5, 0.45, 0.5), rings=3, segments=6)
    return m


# =================================================================================================
# Fountain + statue
# =================================================================================================


def plaque_text(piece, text, y, face_dist, cell, depth, faces=(0.0, 180.0)):
    """`text` on the given faces (yaw degrees from -Z) of a square plinth, readable from outside
    each face (owner R17)."""
    for degrees in faces:
        start = len(piece.bm.verts)
        block_text(piece, text, (0.0, y, -face_dist), cell, depth)  # reads from -Z
        if degrees:
            yaw_new_verts(piece, start, degrees)


def spout_arc(z0, y0, z1, y1, lift, n=7):
    """Points of a spout's water arc in its own YZ plane (parabola with `lift` studs of rise)."""
    pts = []
    for i in range(n + 1):
        t = i / n
        pts.append((0.0, y0 + (y1 - y0) * t + 4 * lift * t * (1 - t), z0 + (z1 - z0) * t))
    return pts


def mini_nuke(body, nose, fins, band, base, length, radius, segments=6):
    """
    Low-poly toy nuke (~130 triangles at 6 segments) for the fountain spouts: capsule body, cone
    nose, a proud band and four chunky fins. Same look as snkit's nuke_body at a quarter of the
    triangles (eight of them sit on the fountain, owner R11 budgets). base = fin bottoms centre.
    """
    bx, by, bz = base
    r = radius
    y0 = by + length * 0.1  # body bottom (the fins lift it)
    y1 = by + length * 0.68  # body top = nose base
    revolve(body, [(0.0, y0), (r * 0.75, y0), (r, y0 + r * 0.35), (r, y1), (0.0, y1)], center=(bx, 0.0, bz), segments=segments)
    revolve(nose, [(0.0, y1), (r * 1.02, y1), (r * 0.62, y1 + (by + length - y1) * 0.62), (0.0, by + length)], center=(bx, 0.0, bz), segments=segments)
    yb = by + length * 0.42
    revolve(band, [(r * 0.98, yb - 0.22), (r * 1.08, yb - 0.18), (r * 1.08, yb + 0.18), (r * 0.98, yb + 0.22)], center=(bx, 0.0, bz), segments=segments)
    fin_h = length * 0.34
    for i in range(4):
        a = math.pi / 4 + i * math.pi / 2
        dx, dz = math.cos(a), math.sin(a)
        outline = [
            (bx + dx * r * 0.5, by, bz + dz * r * 0.5),
            (bx + dx * r * 1.7, by, bz + dz * r * 1.7),
            (bx + dx * r * 1.55, by + fin_h * 0.5, bz + dz * r * 1.55),
            (bx + dx * r * 0.5, by + fin_h, bz + dz * r * 0.5),
        ]
        prism(fins, outline, (-dz, 0, dx), max(0.24, r * 0.4))


def build_monument():
    """
    Toy-nuke fountain: outer pool (white wall, lime band, yellow cap) with a blue mosaic floor under
    clear water and ripple rings (`Ripple` row: one bobbing group); eight little Nukey-coloured toy
    nukes on the cap spray water arcs into the pool; a middle bowl on a column spills a water
    curtain; a square plinth (lime band, yellow cap, cream plaques: "NUKEY" front + back, trefoil
    badges on the sides) carries Hub_NukeyStatue at y = 12.2.
    """
    # Hero landmark budget (6,000) INCLUDING the eight spouts: one mesh set instead of 8 instanced
    # spout models saves 40+ MeshParts and every extra draw; low-poly spouts + rings keep it in.
    m = Model(
        "Hub_Monument",
        "world origin; pool r 26.6 (water 1.7); plinth top (Hub_NukeyStatue pivot) y = 12.2; NUKEY on the -Z / +Z plaques; 8 spouts at r 24.4",
        budget=6000,
    )
    stone = m.piece("Stone", STONE)
    yellow = m.piece("Yellow", YELLOW)
    lime = m.piece("Lime", LIME)
    red = m.piece("Red", TOY_RED)
    mosaic = m.piece("Mosaic", SKY_BLUE)
    floor = m.piece("Floor", FLOOR_BLUE)
    water = m.piece("Water", WATER, material="Smooth", transparency=0.3)
    ripple = m.piece("Ripple", RIPPLE, material="Smooth")
    plaque = m.piece("Plaque", CREAM)
    letters = m.piece("Letters", DEEP_BLUE)
    # Outer pool: wall, proud lime band, yellow cap, mosaic floor, water sheet.
    ring(stone, 22.6, 26.0, 0.0, 2.3, 36, chamfer=0.2)
    revolve(lime, [(25.95, 0.7), (26.3, 0.78), (26.3, 1.32), (25.95, 1.4)], segments=36, closed=True)
    ring(yellow, 22.2, FOUNTAIN_R, 2.3, CAP_TOP, 36, chamfer=0.2)
    ring(floor, 0.0, 22.65, 0.0, 0.35, 32, chamfer=0.0)
    extrude_outline(mosaic, star_outline(0.0, 0.0, 20.0, 8.5, 8, spin=math.radians(22.5)), 0.2, 0.45)
    ring(water, 4.4, 22.65, POOL_TOP - 0.15, POOL_TOP, 36, chamfer=0.0)
    for r in (8.6, 19.6):
        ring_tube(ripple, (0.0, POOL_TOP + 0.08, 0.0), r, 0.35, 0.12, segments=20)
    # Middle bowl on a column, water inside, curtain spilling from the rim, ripple at its foot.
    cylinder(stone, (0.0, 0.0, 0.0), (0.0, 4.9, 0.0), 4.6, segments=16)
    revolve(stone, [(0.0, 4.6), (4.6, 4.6), (9.0, 5.3), (12.0, 6.2), (BOWL_R, 7.0), (0.0, 7.0)], segments=24)
    ring(yellow, 11.4, BOWL_R + 0.35, 6.95, 7.6, 24, chamfer=0.0)
    ring(water, 0.0, 11.6, 7.0, BOWL_WATER, 24, chamfer=0.0)
    revolve(water, [(12.6, 6.95), (12.9, 6.95), (13.7, POOL_TOP + 0.02), (13.3, POOL_TOP + 0.02)], segments=24, closed=True)
    ring_tube(ripple, (0.0, POOL_TOP + 0.08, 0.0), 14.1, 0.4, 0.12, segments=20)
    # Square plinth in the bowl: stone block, proud lime band, yellow cap, cream plaques + letters.
    block(stone, (0.0, (6.9 + PLINTH_TOP - 0.6) / 2, 0.0), (2 * PLINTH_HALF, PLINTH_TOP - 0.6 - 6.9, 2 * PLINTH_HALF), bevel=0.35)
    block(lime, (0.0, 10.9, 0.0), (2 * PLINTH_HALF + 0.4, 0.6, 2 * PLINTH_HALF + 0.4), bevel=0.12)
    block(yellow, (0.0, PLINTH_TOP - 0.3, 0.0), (2 * PLINTH_HALF + 0.8, 0.6, 2 * PLINTH_HALF + 0.8), bevel=0.15)
    face = PLINTH_HALF + 0.2
    for degrees in (0.0, 90.0, 180.0, 270.0):
        start = len(plaque.bm.verts)
        block(plaque, (0.0, 8.95, -face), (9.6, 2.5, 0.4), bevel=0.08)
        if degrees:
            yaw_new_verts(plaque, start, degrees)
    # NUKEY on the -Z / +Z plaques, a raised star on the +-X plaques (letters cost ~300 triangles
    # per face; a star 36).
    cell = min(8.6 / text_cells("NUKEY"), 0.3)
    plaque_text(letters, "NUKEY", 8.95, face + 0.2, cell, 0.18)
    for sx in (-1, 1):
        outline = star_outline(0.0, 8.95, 1.1, 0.5, 5)
        prism(letters, [(sx * (face + 0.29), y, z) for z, y in outline], (1, 0, 0), 0.18)
    # Eight toy-nuke spouts on the cap at yaw 22.5 + 45k (little Nukey-coloured nukes: yellow body,
    # red nose, blue fins, lime band), each spraying a tapering water arc toward the statue that
    # lands in the pool at r 16 with a ripple ring. Built in the fountain's own pieces (no extra
    # MeshParts; HubLayout.anchors.FountainJets / AmbientFx put the spray particles on the nozzles).
    for k in range(8):
        a = math.radians(22.5 + 45 * k)
        x, z = polar(SPOUT_R, a)
        mini_nuke(yellow, red, mosaic, lime, (x, CAP_TOP, z), SPOUT_LEN, 1.2, segments=6)
        local = spout_arc(-0.2, CAP_TOP + SPOUT_LEN - 0.1, -(SPOUT_R - LAND_R), POOL_TOP + 0.05, 3.2)
        # spout_arc runs along -Z from the spout; turn it into the radial plane at yaw a.
        pts = []
        for px, py, pz in local:
            r = SPOUT_R + pz
            wx, wz = polar(r, a)
            pts.append((wx, py, wz))
        tube(water, pts, 0.42, sides=4, radius_end=0.3)
        lx, lz = polar(LAND_R, a)
        ring_tube(ripple, (lx, POOL_TOP + 0.08, lz), 1.3, 0.3, 0.12, segments=6)
    return m


def nukey_figure(m, s=NUKEY_SCALE):
    """
    Giant Nukey (brand mascot, docs/brand.md NUKEY_PALETTE: red cap, sunny yellow body, lime belt,
    toy-blue fins) standing on y = 0 facing -Z: big shiny eyes, rosy cheeks, wide smile, left fist
    on the hip, right arm waving. The waving arm (WaveArm + WaveGlove) is balanced about the
    shoulder so WorldFx's `Wave` row turns it about the joint.
    """
    body = m.piece("Body", YELLOW)
    nose = m.piece("Nose", TOY_RED)
    fins = m.piece("Fins", SKY_BLUE)
    core = m.piece("Core", LIME, material="Smooth")
    white = m.piece("Gloves", WHITE)
    eyes = m.piece("Eyes", WHITE, material="Smooth")
    dark = m.piece("Dark", CHARCOAL, material="Smooth")
    pink = m.piece("Cheeks", PINK)
    arm = m.piece("WaveArm", YELLOW)
    glove = m.piece("WaveGlove", WHITE)
    r = 3.8 * s

    def S(x, y, z):
        return (x * s, y * s, z * s)

    nuke_body(body, nose, fins, core, base=(0.0, 0.0, 0.0), length=18.0 * s, radius=r, fin_count=4, segments=28)

    def surface_z(x):
        """Front (-Z) surface of the round body at horizontal offset x (studs, scaled)."""
        return -math.sqrt(max(r * r - x * x, 0.01))

    # Eyes, pupils (looking slightly inward), highlights, brows, cheeks.
    for side in (-1, 1):
        ex = side * 1.45 * s
        ez = surface_z(ex) + 0.12 * s
        ellipsoid(eyes, (ex, 10.6 * s, ez), (1.05 * s, 1.45 * s, 0.6 * s), rings=8, segments=14)
        ellipsoid(dark, (side * 1.3 * s, 10.4 * s, ez - 0.5 * s), (0.55 * s, 0.78 * s, 0.3 * s), rings=6, segments=12)
        ellipsoid(eyes, (side * 1.3 * s + 0.22 * s, 10.78 * s, ez - 0.78 * s), (0.22 * s, 0.26 * s, 0.12 * s), rings=4, segments=8)
        bar(dark, (side * 0.65 * s, 12.3 * s, surface_z(0.65 * s) - 0.08), (side * 2.25 * s, 12.65 * s, surface_z(2.25 * s) - 0.08), 0.26 * s)
        ellipsoid(pink, (side * 2.55 * s, 9.0 * s, surface_z(2.55 * s) + 0.05 * s), (0.75 * s, 0.48 * s, 0.3 * s), rings=5, segments=10)
    # Smile: chunky curved line hugging the body front.
    pts = []
    for i in range(9):
        t = -1.0 + i * 0.25
        x = 1.45 * s * t
        pts.append((x, (8.2 + 0.5 * t * t) * s, surface_z(x) - 0.06 * s))
    for a, b in zip(pts, pts[1:]):
        bar(dark, a, b, 0.34 * s)
    # Shine on the red cap (white oval, upper left like the brand art).
    ellipsoid(eyes, (-1.3 * s, 14.7 * s, -math.sqrt(max((0.93 * r) ** 2 - (1.3 * s) ** 2, 0.01))), (0.55 * s, 0.95 * s, 0.3 * s), rings=5, segments=10)
    # Belly badge: white disc + black trefoil under the belt.
    by = 4.0 * s
    revolve(eyes, [(0.0, -0.35 * s), (1.35 * s, -0.35 * s), (1.35 * s, 0.35 * s), (0.0, 0.35 * s)], center=(0.0, by, surface_z(0.0) + 0.27 * s), segments=18, rot=rot_x(90))
    trefoil(dark, (0.0, by, surface_z(0.0) - 0.12 * s), 1.1 * s, 0.08 * s, normal=(0, 0, -1))
    # Left fist on the hip (static, body colour + white glove).
    sh_l, el_l, wr_l = S(-3.4, 9.4, 0.0), S(-6.2, 7.2, 0.5), S(-4.6, 5.4, -0.4)
    cylinder(body, sh_l, el_l, 0.8 * s, segments=12)
    ellipsoid(body, el_l, (0.84 * s, 0.84 * s, 0.84 * s), rings=5, segments=10)
    cylinder(body, el_l, wr_l, 0.72 * s, segments=12)
    ellipsoid(white, S(-4.3, 5.1, -0.6), (1.1 * s, 1.0 * s, 0.95 * s), rings=6, segments=12)
    # Right arm waving: upper arm out, forearm up, cuff + open glove with thumb.
    sh_r, el_r, wr_r = S(3.4, 9.4, 0.0), S(6.0, 11.0, -0.5), S(6.6, 14.2, -0.9)
    cylinder(arm, sh_r, el_r, 0.8 * s, segments=12)
    ellipsoid(arm, el_r, (0.82 * s, 0.82 * s, 0.82 * s), rings=5, segments=10)
    cylinder(arm, el_r, wr_r, 0.72 * s, segments=12)
    d = (Vector(wr_r) - Vector(el_r)).normalized()
    w = Vector(wr_r)
    cylinder(glove, tuple(w - d * 0.2 * s), tuple(w + d * 0.5 * s), 0.95 * s, segments=12)
    g = w + d * 1.45 * s
    ellipsoid(glove, tuple(g), (1.15 * s, 1.3 * s, 0.85 * s), rings=6, segments=12)
    ellipsoid(glove, (g.x - 0.95 * s, g.y - 0.2 * s, g.z - 0.2 * s), (0.4 * s, 0.55 * s, 0.4 * s), rings=4, segments=8)

    body_y0 = 18.0 * s * 0.28 * 0.35  # nuke_body: fin_h * 0.35

    def inside_body(p):
        """True when p is inside the body capsule (radius >= 0.7 r from its bottom up): hidden."""
        return math.hypot(p[0], p[2]) < r * 0.62 and body_y0 + 0.1 < p[1] < 18.0 * s * 0.8

    # Wave turns about the arm's Z axis through the shoulder joint (just inside the body surface).
    shoulder = (sh_r[0] - 0.3 * s, sh_r[1], 0.0)
    balance_about(arm, shoulder, axes=(0, 1), hide_check=inside_body)
    balance_about(glove, shoulder, axes=(0, 1), hide_check=inside_body)


def build_nukey_statue():
    """Hub hero: giant waving Nukey (31.5 tall) standing on the fountain plinth, facing -Z."""
    m = Model("Hub_NukeyStatue", "fin bottoms centre on the plinth top (y 12.2 in the world); Nukey faces -Z; tip at y = 31.5", budget=6000)
    nukey_figure(m)
    return m


def build_coin_halo():
    """Eight gold coins on a ring (r 7) that orbits slowly above Nukey's head (`Carousel` row)."""
    m = Model("Hub_CoinHalo", "ring centre; 8 coins on r = 7 facing outward; spins about +Y", budget=1500)
    gold = m.piece("Carousel", GOLD, material="StudsSmall")
    for i in range(8):
        a = TAU * i / 8
        x, z = polar(7.0, a)
        # Alternate heights (+-0.5) so the halo reads as a playful wobbling crown, still symmetric.
        coin(gold, (x, 0.5 if i % 2 == 0 else -0.5, z), 1.5, 0.45, normal_yaw=math.degrees(a), segments=12)
    return m


def build_coin():
    """Big floating gold coin (`Whirl` row spins it about +Y). Pivot = coin centre."""
    m = Model("Hub_Coin", "coin centre; faces +-Z; spins about +Y", budget=400)
    coin(m.piece("Whirl", GOLD, material="StudsSmall"), (0.0, 0.0, 0.0), 1.8, 0.5, segments=18)
    return m


# =================================================================================================
# Street dressing
# =================================================================================================


def build_banner_pole():
    """
    Tall white pole (ball finials, T crossbar) with a yellow swallow-tail banner: lime border
    and a lime star on both faces. Banner pieces (`Streamer` row) twist gently about their centre.
    """
    m = Model("Hub_BannerPole", "ground centre; banner faces -Z (y 7-15.2); pole top y = 17.4", budget=900)
    pole = m.piece("Pole", STONE)
    finial = pole  # white ball finials share the pole piece (one draw)
    flag = m.piece("Streamer", YELLOW)
    trim = m.piece("StreamerTrim", LIME)
    block(pole, (0.0, 0.3, 0.45), (1.6, 0.6, 1.6), bevel=0.15)
    cylinder(pole, (0.0, 0.6, 0.45), (0.0, 16.9, 0.45), 0.32, segments=10)
    ellipsoid(finial, (0.0, 17.3, 0.45), (0.55, 0.55, 0.55), rings=5, segments=10)
    # Crossbar in front of the pole; the banner's top edge tucks into it (y 15.5).
    bar(pole, (-2.7, 15.6, 0.0), (2.7, 15.6, 0.0), 0.36)
    for x in (-2.7, 2.7):
        ellipsoid(finial, (x, 15.6, 0.0), (0.32, 0.32, 0.32), rings=4, segments=8)
    # Banner (plane z = -0.05, 0.16 thick) hangs from the crossbar: swallow tail at the bottom.
    w, top, bottom, notch = 4.6, 15.5, 7.0, 1.4
    outline = [(-w / 2, top), (w / 2, top), (w / 2, bottom), (0.0, bottom + notch), (-w / 2, bottom)]
    prism(flag, [(x, y, -0.05) for x, y in outline], (0, 0, 1), 0.16)
    # Lime border just proud of both faces (bars round an inset outline) + a star on both faces.
    inset = [(-w / 2 + 0.25, top - 0.25), (w / 2 - 0.25, top - 0.25), (w / 2 - 0.25, bottom + 0.35), (0.0, bottom + notch + 0.3), (-w / 2 + 0.25, bottom + 0.35)]
    for zf in (-0.17, 0.07):
        for (x0, y0), (x1, y1) in zip(inset, inset[1:] + inset[:1]):
            bar(trim, (x0, y0, zf), (x1, y1, zf), 0.22)
        star = star_outline(0.0, 11.6, 1.5, 0.65, 5)
        prism(trim, [(x, z, zf) for x, z in star], (0, 0, 1), 0.08)
    return m


def build_bunting():
    """
    Spoke-mouth gateway: two toy lamp posts (dark pole, yellow collar + cap, warm globe) at
    x = +-10.6 with a pennant string between them (hooks at x = +-10.3, y 10.1, sag 1.4; 11
    double-sided pennants alternating yellow / lime). The rope + pennants share the `Pennant` row,
    so the string swings as one; the posts never move. One model per gateway (posts + string)
    keeps the lobby's MeshPart count down; the two globes share one piece, so they render as soft
    warm plastic, never Neon (owner R19).
    """
    m = Model("Hub_Bunting", "ground centre of the span; lamp posts at x = +-10.6; string hooks at (+-10.3, 10.1, 0) in the XY plane", budget=1200)
    post = m.piece("Post", (92, 98, 112))
    cap = m.piece("Cap", YELLOW)
    globe = m.piece("Globe", (255, 236, 160), material="Smooth")
    rope = m.piece("PennantRope", WHITE, material="Smooth")
    colours = (m.piece("Pennant", YELLOW), m.piece("PennantLime", LIME))
    for side in (-1, 1):
        x = side * 10.6
        block(post, (x, 0.4, 0.0), (1.6, 0.8, 1.6), bevel=0.15)
        cylinder(post, (x, 0.8, 0.0), (x, 11.0, 0.0), 0.3, segments=10)
        ring(cap, 0.0, 0.55, 2.0, 2.4, 10, chamfer=0.08, center=(x, 0.0))
        ring(cap, 0.0, 0.75, 10.8, 11.2, 10, chamfer=0.08, center=(x, 0.0))
        ellipsoid(globe, (x, 12.2, 0.0), (1.1, 1.2, 1.1), rings=6, segments=10)
        revolve(cap, [(0.0, 0.0), (1.2, 0.0), (0.85, 0.5), (0.0, 0.7)], center=(x, 13.15, 0.0), segments=10)
    half, hook_y, sag = 10.3, 10.1, 1.4

    def rope_y(x):
        return hook_y - sag * (1 - (x / half) ** 2)

    tube(rope, [(x, rope_y(x), 0.0) for x in lin(-half, half, 12)], 0.09, sides=5)
    count = 11
    for i in range(count):
        x = -half + (i + 1) * (2 * half) / (count + 1)
        y = rope_y(x)
        tri = [(x - 0.7, y - 0.05, 0.0), (x + 0.7, y - 0.05, 0.0), (x, y - 1.75, 0.0)]
        prism(colours[i % 2], tri, (0, 0, 1), 0.1)
    return m


# =================================================================================================
# Pads
# =================================================================================================


def build_teleport_pad():
    """
    Plot teleport pad + signpost: white round pad, tinted rim + chevrons (point +Z = to the plot);
    behind it a white two-post sign with a tinted frame, the cream `Label` board (SurfaceGui "PLOT
    N + owner", faces -Z), the plot digit (Hub_Digit, placed by HubLayout) standing on the frame and
    a yellow star that turns slowly on top (`Twirl` row).
    UNUSED since owner R134 (2026-11-01): no hub places teleport pads any more; the builder and the
    uploaded mesh are kept (MeshAssets) only so the asset stays reproducible.
    """
    m = Model(
        "Hub_TeleportPad",
        "ground centre; pad top y = 1.0; arrow points +Z (toward the plot); Label sign at z = +6.4 faces -Z; Accent tinted",
        budget=1500,
    )
    base = m.piece("Base", STONE)
    # Rim, arrows, sign frame and post caps are ONE tinted piece (plot colour, one draw).
    rim = m.piece("Accent", LIME, tinted=True)
    arrow = rim
    frame = rim
    top = m.piece("Top", WHITE)
    label = m.piece("Label", CREAM)
    star = m.piece("Twirl", YELLOW)
    ring(base, 0.0, 5.4, 0.0, 0.5, 28, chamfer=0.15)
    ring(top, 0.0, 4.4, 0.5, 0.85, 28, chamfer=0.1)
    ring(rim, 4.4, 5.3, 0.5, 1.0, 28, chamfer=0.1)
    for zc in (-1.3, 1.3):
        extrude_outline(arrow, chevron_outline(0.0, zc, 4.4, 2.0, 0.95), 0.8, 1.0)
    # Signpost: white posts with tinted caps, tinted frame round the Label board (board top y 9.0,
    # where Hub_Digit<i> stands), a thin rod behind the digit up to the turning star.
    # Posts (x 3.6..4.4) swallow the frame's ends (x +-4.3): no flush side faces (z-fight rule 2).
    for x in (-4.0, 4.0):
        block(base, (x, 0.3, 6.6), (1.4, 0.6, 1.4), bevel=0.12)
        block(base, (x, 4.85, 6.6), (0.8, 8.5, 0.8), bevel=0.1)
        ellipsoid(frame, (x, 9.45, 6.6), (0.62, 0.62, 0.62), rings=5, segments=10)
    block(frame, (0.0, 7.4, 6.6), (8.6, 3.2, 0.6), bevel=0.12)
    block(label, (0.0, 7.4, 6.12), (7.3, 2.6, 0.3), bevel=0.05)
    cylinder(base, (0.0, 9.0, 7.25), (0.0, 16.6, 7.25), 0.22, segments=8)
    # Star: 8 points (symmetric box, so it turns about its own centre), double-faced, y = 17.6.
    outline = star_outline(0.0, 17.6, 1.55, 0.75, 8)
    prism(star, [(x, z, 7.25) for x, z in outline], (0, 0, 1), 0.45)
    return m


def build_spawn_pad():
    """
    Round spawn pad: white top with a big yellow star, lime rim, eight square yellow studs on the rim.
    Encloses HubBuilder's 12 x 1 x 12 SpawnLocation (centre y 0.5, half-diagonal 8.49 < 8.7), so
    the plain spawn part never shows; players stand on y = 1.0, level with the pad top (1.05).
    """
    m = Model("Hub_SpawnPad", "ground centre; pad top y = 1.05 (star top 1.25); encloses a 12x1x12 SpawnLocation", budget=800)
    base = m.piece("Base", WHITE)
    star = m.piece("Star", YELLOW)
    rim = m.piece("Rim", LIME)
    ring(base, 0.0, 8.7, 0.0, 1.05, 24, chamfer=0.15)
    ring(rim, 8.7, 9.5, 0.0, 1.3, 24, chamfer=0.15)
    extrude_outline(star, star_outline(0.0, 0.0, 6.0, 2.7), 0.95, 1.25)
    # Eight square yellow studs on the rim (12 triangles each).
    for i in range(8):
        x, z = polar(9.1, TAU * (i + 0.5) / 8)
        box(star, (x, 1.4, z), (0.6, 0.3, 0.6), rot=rot_y(math.degrees(TAU * (i + 0.5) / 8)))
    return m


BUILDERS = {
    "Hub_CenterPlaza": build_center_plaza,
    "Hub_PlazaSpoke": build_plaza_spoke,
    "Hub_PlazaGarden": build_plaza_garden,
    "Hub_Monument": build_monument,
    "Hub_NukeyStatue": build_nukey_statue,
    "Hub_CoinHalo": build_coin_halo,
    "Hub_Coin": build_coin,
    "Hub_BannerPole": build_banner_pole,
    "Hub_Bunting": build_bunting,
    "Hub_TeleportPad": build_teleport_pad,
    "Hub_SpawnPad": build_spawn_pad,
}
