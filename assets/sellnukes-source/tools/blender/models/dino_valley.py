"""
dino_valley.py — Dino Valley's world frame: Base Camp, the 8 plot frames, the valley scenery and the
far backdrop (W9 valley-hub-art, owner R57; spec docs/superpowers/specs/2026-10-31-world2-design.md
§2 / §5 / §15 / §16). The cartoon Time Machine that stands at Base Camp is hub_time_machine.py.

WORLD-LOCAL frame (relative to the Valley's world origin, WorldGeometry "dino" = (6000, 0, 0); the
layout is src/shared/Config/Worlds/Dino/ValleyLayout.luau, which mirrors every constant below):
    Base Camp centre at (0, 0, 0), ground top y = 0; plots i = 1..8 at yaw (i-1)*45° with their
    origin at radius 260 (exactly Nuke Town's ring), plot length 312 (3 rows, 6 slots).
    Layers (z-fight rule R18: never two walk surfaces on one plane, curved seams only between
    different heights):
        Valley_Ground       r 0..662   top -0.40   valley floor (under everything, past the cliffs)
        Valley_BaseCamp     r 0..244   top  0.00   meadow grass
                            r 25.6..88 top  0.18   flagstone plaza ring (+ stone inlays 0.24)
                            welcome walk (yaw 22.5, r 87.6..122) top 0.12
        Valley_RingPath x8  r 230..260 top  0.06   sandy ring path (straight 20-stud mouth at each
                                                   plot entrance so the plot path butts it straight)
        Valley_Trail x8     r 87.4..236 top 0.12   sandy trail from the plaza to each plot
        Valley_PlotGround   plot-local top 0.00    (different height from the ring path: no seam)
        Valley_Path         plot-local top 0.06 (+ edging 0.40, stepping-stone tiles 0.12)
    Boundary: Valley_BoundaryCliffs x8 (45° arcs) foot r 652 leaning in to r 644 at the top,
    invisible collision ring at r 650 (ValleyLayout), far volcano backdrop at r 830.

Models (pivot / front; HubBuilder-style placement in ValleyLayout):
    Base Camp + frame
        Valley_Ground          world-local origin; jungle floor disc (StudsLarge), persistent
        Valley_BaseCamp        world-local origin; meadow, plaza ring + inlays, welcome walk, moss
        Valley_RingPath        world-local origin, arc centred on +Z (spawn at yaw (i-1)*45)
        Valley_Trail           world-local origin, trail along +Z (spawn at yaw (i-1)*45); `Flowers`
                               TINTED with the plot colour
        Valley_BrontoFountain  pond centre on the ground; a friendly long-neck statue faces -Z and
                               spouts a water arc into the pond (Ripple ring bobs via WorldFx)
        Valley_TitleSign       ground centre between the posts; "DINO VALLEY" letters on BOTH faces
        Valley_TeleportPad     ground centre; pad top y 1.0; Label (7.3 x 2.6) front face z = 5.97
                               faces -Z; board top y 9.0 (Hub_Digit<i> stands at (0, 9.0, 6.45));
                               `Accent` TINTED (plot colour). Same anchor numbers as Hub_TeleportPad.
        Valley_EggStand        ground centre; egg pivot (0, 4.0, 0) in a twig nest; Sign (9.2 x 3.2)
                               front face z = 2.72; `Accent` TINTED. Same numbers as Hub_EggStand.
        Valley_Leaderboard     ground centre; stone tablet, Screen (12.8 x 17.8) front face
                               z = -0.25 at y 12.9; `Frame` TINTED. Same numbers as Hub_Leaderboard.
    Plot frame (PLOT-LOCAL: origin = entrance centre on the ring path, +Z away from Base Camp)
        Valley_PlotGround      two jungle plates x in [-80,-10] / [10,80], curved front, back z 312
        Valley_Path            sand path |x| <= 8 (z 0..312.6), stone edging 8..10 (top 0.4),
                               stepping-stone tiles
        Valley_FernHedge       hedge just OUTSIDE the footprint (x = +-[80.2, 82.6], z = [312.2,
                               314.6]); `Blossoms` TINTED (plot colour)
        Valley_EntranceArch    plot-local (0, 0, 4): boulder pillars at x = +-13 (5 x 5), log beam,
                               `OwnerSign` panels front z = -1.85 / back z = +1.85 (22 x 3.6) for the
                               "<Name>'s Dino Nukes" SurfaceGui; `Accent` TINTED
        Valley_LockedSlot      SLOT-local; bamboo fence across the slot front, vine-covered
                               "COMING SOON" board (`Sign`, front face z = 4.19), a nest of three
                               giant eggs waiting to hatch. Same sign numbers as Plot_LockedSlot.
    Scenery (ground pivot, front -Z)
        Valley_Palm, Valley_Fern, Valley_Boulder, Valley_Hill, Valley_FossilDecor (giant cartoon
        bones half dug out + an ammonite shell; no skulls), Valley_Waterfall (falls into a pool,
        placed against the cliffs), Valley_BoundaryCliffs (45° arc, world-local origin, centred on
        +Z), Valley_VolcanoBackdrop (far, low-poly, friendly smoking volcano with candy lava)

Budgets (docs/world-art.md §4; spec §15 Base Camp first view <= 700 MeshParts / 150k triangles /
<= 45 unique meshes, measured in tests/valley-layout.luau): floors <= 3,000, fixtures <= 3,000,
hero (fountain, title sign) <= 6,000, cliffs <= 3,000 per arc, volcano <= 2,500.

Kid-friendly (spec §2): round, smiling dinos, candy-orange "warm jelly" lava, bones are cartoon
dog-bones, the fossil decor shows bones + a shell, never a skull.

Example:
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only Valley_BaseCamp
"""

from __future__ import annotations

import math

from mathutils import Vector

from models._critter_kit import eyes, smile, tube
from models.area01 import sign_text, text_cells
from models.area04 import _hash
from models.dino_area01 import (
    AMBER,
    AMBER_GLOW,
    BAMBOO,
    BARK,
    BONE,
    FERN,
    FERN_DARK,
    INK,
    LAVA,
    LOG,
    LOG_END,
    MOSS,
    SAND,
    SAND_DARK,
    STONE,
    STONE_DARK,
    boulder,
    fern,
    log,
    palm,
    pebble_nuke,
)
from models.dino_area01 import bone as cartoon_bone
from models.hub import lin, polar, ring, slab
from models.plotframe import band_outline, front_z, rect_outline
from snkit.core import CREAM, Model, PINK, WHITE
from snkit.kit import block, sign_frame
from snkit.shapes import box, cylinder, ellipsoid, extrude_outline, loft, prism, revolve, rot_y

TAU = 2 * math.pi

# ---- Valley palette additions (the shared Dino palette lives in models.dino_area01) ------------
VALLEY_FLOOR = (84, 150, 62)  # far valley floor (a touch darker than the lots)
MEADOW = (112, 186, 76)  # Base Camp meadow
PLOT_FLOOR = (96, 164, 66)  # plot ground under the lots
FLAGSTONE = (226, 204, 156)  # plaza ring (warm sandstone)
WATER = (90, 196, 255)  # pond / waterfall (Smooth, like Hub_Monument)
FOAM = (214, 246, 255)
BRONTO = (132, 222, 140)  # the fountain dino's skin
BRONTO_SPOTS = (96, 184, 118)
LEAF_PAD = (88, 190, 92)
HAT = (214, 176, 110)  # explorer hat (khaki)
CLIFF = (176, 150, 112)  # boundary cliff rock
CLIFF_DARK = (140, 118, 92)
VOLCANO = (188, 132, 108)
VOLCANO_DARK = (150, 104, 88)
SMOKE = (236, 232, 240)
SLATE = (44, 52, 70)  # leaderboard screen (same as Hub_Leaderboard)

# ---- World-local dimensions (ValleyLayout.luau mirrors these; change both together) ------------
PLOT_R = 260.0  # plot origin radius (= ring path outer edge)
RING_IN = 230.0  # ring path inner radius
GRASS_R = 244.0  # meadow disc radius (tucks under the ring path)
PLAZA_IN, PLAZA_OUT = 25.6, 88.0  # flagstone plaza ring
PLAZA_TOP = 0.18
TRAIL_TOP = 0.12
RING_TOP = 0.06
TRAIL_HALF = 9.0
TRAIL_Z0, TRAIL_Z1 = 87.4, 236.0
MOUTH_HALF = 10.0  # straight ring-path mouth at each plot entrance (|x| <= 10)
POND_R = 22.4  # pond water radius; basin rim r 22..26 (top 1.6)
RIM_TOP = 1.6
WATER_TOP = 1.0
PLOT_LEN = 312.0
PLOT_HALF = 80.0
CURB_HALF = 10.0
ROAD_HALF = 8.0
CLIFF_FOOT_R = 652.0  # cliff foot (the collision ring is at r 650)
CLIFF_TOP_R = 644.0
GROUND_R = 662.0
SPAWN_YAW = 22.5  # spawn faces outward along this yaw (mirrors Nuke Town)


def _pt(r, yaw_rad, y):
    """World-local point at radius r / yaw (radians from +Z toward +X), height y."""
    x, z = polar(r, yaw_rad)
    return (x, y, z)


# =================================================================================================
# Base Camp floor
# =================================================================================================


def build_ground():
    """Valley floor disc r 0..662 (top y = -0.4), under Base Camp, the plots, the wedges and the cliffs."""
    m = Model("Valley_Ground", "world-local origin (Base Camp centre); top y = -0.4; r <= 662", budget=600)
    ground = m.piece("Ground", VALLEY_FLOOR, material="StudsLarge")
    ring(ground, 0.0, GROUND_R, -2.0, -0.4, 72, chamfer=0.0)
    return m


def build_base_camp():
    """
    Base Camp floor: meadow disc (top 0), flagstone plaza ring r 25.6..88 (top 0.18) with stone
    inlays (0.24, inner + outer bands only: never under the Time Machine or the teleport pads), the
    welcome walk from the plaza to the title sign (yaw 22.5, top 0.12) and moss patches on the
    meadow between the trails (top 0.06).
    """
    m = Model("Valley_BaseCamp", "world-local origin; meadow top 0, plaza ring r 25.6-88 top 0.18", budget=3500)
    grass = m.piece("Grass", MEADOW)
    plaza = m.piece("Plaza", FLAGSTONE)
    stones = m.piece("Stones", STONE)
    sand = m.piece("Sand", SAND)
    moss = m.piece("Moss", MOSS)
    ring(grass, 0.0, GRASS_R, -1.0, 0.0, 72, chamfer=0.2)
    ring(plaza, PLAZA_IN, PLAZA_OUT, -0.3, PLAZA_TOP, 72, chamfer=0.08)
    # Stone inlays: two bands of flat irregular slabs (embedded 0.02 into the plaza: no shared plane).
    for band_r, count, size in ((31.5, 18, 2.6), (83.0, 40, 3.0)):
        for k in range(count):
            a = TAU * (k + 0.5 * _hash(k, band_r)) / count
            x, y, z = _pt(band_r + (_hash(k + 3, band_r) - 0.5) * 1.6, a, 0.0)
            w = size * (0.8 + 0.4 * _hash(k + 7, band_r))
            d = size * (0.7 + 0.4 * _hash(k + 11, band_r))
            box(stones, (x, PLAZA_TOP + 0.02, z), (w, 0.08, d), rot=rot_y(math.degrees(a) + 20 * _hash(k, 5.0)))
    # Welcome walk: plaza edge -> title sign along the spawn axis.
    walk = rect_outline(-6.0, 6.0, PLAZA_OUT - 0.4, 122.0)
    c, s = math.cos(math.radians(SPAWN_YAW)), math.sin(math.radians(SPAWN_YAW))

    def walk_at(d):
        return [(x * c + z * s, -x * s + z * c) for x, z in walk(d)]

    slab(sand, walk_at, -0.3, TRAIL_TOP, chamfer=0.04)
    # Moss patches on the meadow (wedge-local, mirrored in every wedge; clear of the trails, the
    # egg stands / title sign / leaderboard spots in ValleyLayout).
    spots = ((-18.0, 150.0, 6.0), (20.0, 176.0, 5.0), (-30.0, 205.0, 7.0), (8.0, 214.0, 4.5))
    for k in range(8):
        if k == 0:
            continue  # spawn wedge: kept clean (egg stands, walk, title sign)
        beta = math.radians(22.5 + 45 * k)
        for i, (lx, lz, r) in enumerate(spots):
            cx = lx * math.cos(beta) + lz * math.sin(beta)
            cz = -lx * math.sin(beta) + lz * math.cos(beta)
            pts = []
            for j in range(9):
                a = TAU * j / 9
                rr = r * (0.75 + 0.35 * _hash(k * 13 + i, j))
                pts.append((cx + math.cos(a) * rr, cz + math.sin(a) * rr * 0.8))
            extrude_outline(moss, pts, -0.04, 0.06)
    return m


def build_ring_path():
    """
    45° of the sandy ring path r 230..260 centred on +Z (top 0.06), with a STRAIGHT mouth
    (|x| <= 10, z = 260) where the plot path starts, and pebbles along the outer edge.
    """
    m = Model("Valley_RingPath", "world-local origin; arc centred on +Z, yaw +-22.5; top y = 0.06", budget=900)
    path = m.piece("Path", SAND_DARK)
    pebbles = m.piece("Pebbles", STONE)
    half = math.radians(22.5)
    mouth_a = math.asin(MOUTH_HALF / PLOT_R)
    outer_l = [polar(PLOT_R, a) for a in lin(-half, -mouth_a, 9)]
    outer_r = [polar(PLOT_R, a) for a in lin(mouth_a, half, 9)]
    inner = [polar(RING_IN, a) for a in lin(half, -half, 18)]
    outline = outer_l + [(-MOUTH_HALF, PLOT_R), (MOUTH_HALF, PLOT_R)] + outer_r + inner
    extrude_outline(path, outline, -0.3, RING_TOP)
    for i, a in enumerate(lin(-half + 0.03, half - 0.03, 10)):
        if abs(math.sin(a) * 255) < MOUTH_HALF + 2:
            continue
        x, z = polar(255.5 + 2.0 * _hash(i, 2.0), a)
        ellipsoid(pebbles, (x, RING_TOP + 0.02, z), (1.1, 0.16, 0.8), rings=3, segments=6)
    return m


def build_trail():
    """
    Sandy trail along +Z from the plaza (z 87.4) to the ring path (z 236), |x| <= 9 (top 0.12), log
    edging on both sides, stepping stones down the middle and plot-coloured flower clumps
    (`Flowers`, TINTED) with ferns along the edges.
    """
    m = Model("Valley_Trail", "world-local origin; trail along +Z (yaw (i-1)*45); top y = 0.12; Flowers tinted", budget=3000)
    sand = m.piece("Sand", SAND)
    logs = m.piece("Logs", LOG)
    ends = m.piece("LogEnds", LOG_END)
    stones = m.piece("Stones", STONE)
    flowers = m.piece("Flowers", PINK, tinted=True)
    leaves = m.piece("Leaves", FERN)
    slab(sand, rect_outline(-TRAIL_HALF, TRAIL_HALF, TRAIL_Z0, TRAIL_Z1), -0.3, TRAIL_TOP, chamfer=0.04)
    # Log edging in 16-stud pieces with small gaps (each log a round cylinder lying on the meadow).
    z = TRAIL_Z0 + 3.0
    while z + 14.0 < 226.0:
        for sx in (-1, 1):
            log(logs, (sx * (TRAIL_HALF + 0.55), 0.4, z), (sx * (TRAIL_HALF + 0.55), 0.4, z + 14.0), 0.48, segments=6, ends=ends)
        z += 16.0
    # Stepping stones down the middle.
    i = 0
    for zz in lin(TRAIL_Z0 + 8.0, TRAIL_Z1 - 14.0, 11):
        x = (-1.8 if i % 2 == 0 else 1.8) + (_hash(i, 4.0) - 0.5)
        block(stones, (x, TRAIL_TOP + 0.03, zz), (3.6, 0.1, 2.8), bevel=0.03, rot=rot_y(15 * (_hash(i, 9.0) - 0.5)))
        i += 1
    # Flower clumps + ferns along the outside of the logs.
    for j, zz in enumerate(lin(TRAIL_Z0 + 12.0, 216.0, 5)):
        for sx in (-1, 1):
            cx = sx * (TRAIL_HALF + 2.6)
            for b in range(3):
                a = TAU * b / 3 + j
                ellipsoid(flowers, (cx + math.cos(a) * 0.7, 0.75, zz + math.sin(a) * 0.7), (0.42, 0.34, 0.42), rings=3, segments=6)
            fern(leaves, (cx, 0.0, zz + 3.0 * sx), size=0.9, seed=j * 2 + (sx > 0), fronds=3)
    return m


# =================================================================================================
# Base Camp fixtures
# =================================================================================================


BRONTO_S = 1.55  # dino scale about its feet (head ~45 up: it peeks over the Time Machine)
BRONTO_Y0 = 2.4  # feet height on the rock island
BRONTO_MOUTH = (0.0, BRONTO_Y0 + (26.1 - BRONTO_Y0) * BRONTO_S, -12.3 * BRONTO_S)  # spout nozzle
BRONTO_LAND_Z = -18.5  # the arc lands in the pond here (ripple rings reach r 21.2 < POND_R)
BRONTO_CTRL = (0.0, BRONTO_MOUTH[1] + 7.0, -22.5)  # Bezier control: the spout rises, bows out, falls


def _neck_path(t):
    """Bronto neck centre-line (local): from the shoulders up and forward to the head."""
    p0 = Vector((0.0, 9.6, -3.0))
    p1 = Vector((0.0, 20.0, -4.0))
    p2 = Vector((0.0, 26.0, -9.5))
    a = p0.lerp(p1, t)
    b = p1.lerp(p2, t)
    return a.lerp(b, t)


def build_bronto_fountain():
    """
    Hero: a round friendly long-neck dino in a little explorer hat stands on a mossy rock island in
    the middle of a stone-rimmed pond and spouts a water arc from its smile into the pond (the
    landing ring is `Ripple`, which bobs via WorldFx). Faces -Z.
    """
    m = Model(
        "Valley_BrontoFountain",
        "pond centre on the ground; rim r 22-26 top 1.6, water top 1.0; dino faces -Z; mouth (0, 39.1, -19.1)",
        budget=6000,
    )
    rim = m.piece("Rim", STONE)
    water = m.piece("Water", WATER, material="Smooth")
    ripple = m.piece("Ripple", FOAM, material="Smooth")
    rocks = m.piece("Rocks", STONE_DARK)
    moss = m.piece("Moss", MOSS)
    skin = m.piece("Skin", BRONTO)
    belly = m.piece("Belly", CREAM)
    spots = m.piece("Spots", BRONTO_SPOTS)
    ink = m.piece("Ink", INK, material="Smooth")
    shine = m.piece("Shine", WHITE, material="Smooth")
    lily = m.piece("Lily", LEAF_PAD)
    hat = m.piece("Hat", HAT)
    # Pond: basin wall + water + lily pads with pink buds.
    ring(rim, 22.0, 26.0, -0.6, RIM_TOP, 56, chamfer=0.3)
    ring(water, 0.0, POND_R, 0.2, WATER_TOP, 56, chamfer=0.0)
    for k in range(7):
        a = TAU * k / 7 + 0.4
        r = 15.5 + 3.0 * _hash(k, 1.0)
        x, z = polar(r, a)
        if z < -12:  # keep the spout's landing zone clear
            continue
        cylinder(lily, (x, WATER_TOP - 0.02, z), (x, WATER_TOP + 0.1, z), 1.4 + 0.4 * _hash(k, 2.0), segments=10)
        ellipsoid(hat if k % 3 == 0 else spots, (x + 0.4, WATER_TOP + 0.35, z), (0.35, 0.3, 0.35), rings=3, segments=6)
    # Rock island + moss caps.
    for i, (x, z, rx, ry) in enumerate(((0.0, 2.0, 6.5, 2.6), (-4.5, 6.5, 3.4, 2.0), (4.2, 5.8, 3.0, 1.8), (2.0, -3.0, 3.2, 1.6))):
        boulder(rocks, (x, 1.0, z), (rx, ry, rx * 0.85), seed=40 + i, rings=4, segments=8)
        ellipsoid(moss, (x - 0.3, 1.0 + ry * 0.78, z + 0.2), (rx * 0.6, 0.35, rx * 0.5), rings=3, segments=8)
    # The dino is authored at "unit" size and scaled by BRONTO_S about its feet (y = BRONTO_Y0),
    # so it towers ~38 studs over the pond (hero landmark, seen from the whole plaza).
    def P(x, y, z):
        return (x * BRONTO_S, BRONTO_Y0 + (y - BRONTO_Y0) * BRONTO_S, z * BRONTO_S)

    def R(r):
        return tuple(v * BRONTO_S for v in r) if isinstance(r, tuple) else r * BRONTO_S

    # Body, belly, legs, tail.
    ellipsoid(skin, P(0.0, 7.4, 2.5), R((4.4, 3.8, 6.4)), rings=8, segments=14)
    ellipsoid(belly, P(0.0, 6.1, 1.6), R((3.2, 2.4, 4.8)), rings=6, segments=12)
    for sx in (-1, 1):
        for z in (-0.6, 5.6):
            cylinder(skin, P(sx * 2.7, 2.6, z), P(sx * 2.7, 6.0, z), R(1.35), segments=10)
            ellipsoid(skin, P(sx * 2.7, 2.9, z - 0.3), R((1.55, 0.7, 1.75)), rings=4, segments=8)
    # Tail curls sideways so its tip stays inside the pond (z <= 21 at this scale).
    tail = [P(0.0, 7.2, 8.4), P(0.0, 6.0, 11.0), P(1.2, 4.2, 12.6), P(2.8, 2.4, 13.2)]
    tube(skin, tail, R(1.6), sides=8, radii=[R(2.2), R(1.6), R(1.0), R(0.45)])
    # Back spots.
    for x, y, z, r in ((0.0, 10.9, 3.0, 1.3), (-2.2, 10.2, 5.8, 0.9), (2.4, 10.3, 0.4, 1.0), (1.6, 10.6, 6.6, 0.7)):
        ellipsoid(spots, P(x, y, z), R((r, 0.5, r)), rings=3, segments=8)
    # Neck (tapering tube along a quadratic curve) + head.
    path = [P(*tuple(_neck_path(t))) for t in lin(0.0, 1.0, 7)]
    radii = [R(2.3 - 1.0 * t) for t in lin(0.0, 1.0, 7)]
    tube(skin, path, R(2.0), sides=10, radii=radii)
    head_c, head_r = P(0.0, 26.4, -10.4), R((2.0, 1.75, 2.7))
    ellipsoid(skin, head_c, head_r, rings=7, segments=12)
    eyes(ink, shine, head_c, head_r, yaw=32.0, pitch=18.0, size=0.2, tall=1.3)
    smile(ink, head_c, head_r, pitch=-14.0, width=18.0, depth=5.0, thickness=0.09)
    for sx in (-1, 1):
        ellipsoid(spots, P(sx * 1.55, 25.9, -11.6), R((0.45, 0.32, 0.2)), rings=3, segments=6)  # cheeks
    # Little explorer hat.
    cylinder(hat, P(0.0, 27.85, -10.2), P(0.0, 28.0, -10.2), R(2.3), segments=14)
    hat_c = P(0.0, 0.0, -10.2)
    revolve(
        hat,
        [(R(0.0), P(0, 29.6, 0)[1]), (R(0.9), P(0, 29.5, 0)[1]), (R(1.3), P(0, 28.9, 0)[1]), (R(1.35), P(0, 28.0, 0)[1]), (0.0, P(0, 28.0, 0)[1])],
        center=(hat_c[0], 0.0, hat_c[2]),
        segments=12,
    )
    cylinder(belly, P(0.0, 28.0, -10.2), P(0.0, 28.35, -10.2), R(1.38), segments=12)
    # Water arc: from the smile forward and down into the pond (lands at BRONTO_LAND, r < POND_R).
    mouth = Vector(BRONTO_MOUTH)
    land = Vector((0.0, WATER_TOP, BRONTO_LAND_Z))
    ctrl = Vector(BRONTO_CTRL)
    arc = []
    for t in lin(0.0, 1.0, 9):
        a = mouth.lerp(ctrl, t)
        b = ctrl.lerp(land, t)
        arc.append(tuple(a.lerp(b, t)))
    tube(water, arc, 0.6, sides=8, radii=[0.5, 0.6, 0.66, 0.68, 0.68, 0.66, 0.62, 0.58, 0.55, 0.55])
    ring(ripple, 1.2, 1.9, WATER_TOP - 0.05, WATER_TOP + 0.12, 16, chamfer=0.0, center=(0.0, BRONTO_LAND_Z))
    ring(ripple, 2.3, 2.7, WATER_TOP - 0.05, WATER_TOP + 0.08, 16, chamfer=0.0, center=(0.0, BRONTO_LAND_Z))
    return m


def _letters_board(m, lines, center, width, height, depth, cell):
    """Log-framed plank board with block letters on BOTH faces (owner R17); returns nothing."""
    cx, cy, cz = center
    panel = m.piece("Panel", LOG)
    frame = m.piece("Frame", BARK)
    letters = m.piece("Letters", BONE, material="Smooth")
    block(panel, (cx, cy, cz), (width - 0.4, height - 0.4, depth), bevel=0.15)
    for sy in (-1, 1):
        log(frame, (cx - width / 2 - 1.2, cy + sy * height / 2, cz), (cx + width / 2 + 1.2, cy + sy * height / 2, cz), 0.55, segments=8)
    for sx in (-1, 1):
        log(frame, (cx + sx * width / 2, cy - height / 2 + 0.4, cz), (cx + sx * width / 2, cy + height / 2 - 0.4, cz), 0.5, segments=8)
    sign_text(letters, lines, (cx, cy, cz), cell, 0.32, depth / 2)


def build_title_sign():
    """
    "DINO VALLEY" welcome sign (the first thing the spawn faces): stacked mossy boulder posts, a
    log-framed plank board with the name on both faces, a giant cartoon bone crest, pebble-nuke
    finials with small amber Neon bands (R19) and ferns at the post feet.
    """
    m = Model("Valley_TitleSign", "ground centre between the posts; letters on both faces; front -Z", budget=6000)
    posts = m.piece("Posts", STONE)
    posts_dark = m.piece("PostsDark", STONE_DARK)
    moss = m.piece("Moss", MOSS)
    crest = m.piece("Crest", BONE, material="StudsSmall")
    leaves = m.piece("Leaves", FERN)
    lines = ["DINO", "VALLEY"]
    cell = 0.95
    widest = max(text_cells(line) for line in lines)
    board_w = widest * cell + 3.2
    board_h = (7 * 2 + 2) * cell + 2.4
    post_x = board_w / 2 + 1.6
    post_h = 12.0
    for sx in (-1, 1):
        y = 0.0
        for i, (w, h) in enumerate(((5.0, 4.4), (4.4, 4.2), (3.8, post_h - 8.6 + board_h * 0.5))):
            block(posts_dark if i % 2 == 0 else posts, (sx * post_x, y + h / 2, 0.0), (w, h, w), bevel=0.6, segments=2)
            y += h - 0.02
        block(moss, (sx * post_x, y + 0.3, 0.0), (4.0, 0.7, 4.0), bevel=0.3, segments=2)
        for k in range(2):
            fern(leaves, (sx * (post_x + 2.2 - 4.4 * k), 0.0, 1.8 - 3.6 * k), size=1.3, seed=7 + k + (sx > 0) * 3, fronds=5)
    board_y = post_h + board_h / 2
    _letters_board(m, lines, (0.0, board_y, 0.0), board_w, board_h, 1.2, cell)
    top = board_y + board_h / 2 + 0.55
    cartoon_bone(crest, (-5.5, top + 0.75, 0.0), (5.5, top + 0.75, 0.0), 0.55, knob=0.9, segments=10)
    for sx, side in ((-1, "L"), (1, "R")):
        band = m.piece(f"Band{side}", AMBER_GLOW, material="Neon")
        pebble_nuke(posts, band, posts_dark, (sx * post_x, post_h + board_h * 0.5 + 0.62, 0.0), height=3.4)
    m.title_info = {"post_x": post_x, "board_y": board_y, "board_h": board_h, "board_w": board_w}
    return m


def build_teleport_pad():
    """
    Plot teleport pad (Base Camp ring r 62): mossy stone disc with a plot-coloured glowing-top ring
    (`Accent`, TINTED), a leaf ring and footprint arrows to the plot (+Z), and behind it a bamboo
    signpost carrying the cream `Label` (SurfaceGui "PLOT N + owner"). Same anchor numbers as
    Hub_TeleportPad (Label centre (0, 7.4, 6.12), board top 9.0) so the digit and systems reuse them.
    UNUSED since owner R134 (2026-11-01): no hub places teleport pads any more; the builder and the
    uploaded mesh are kept (MeshAssets) only so the asset stays reproducible.
    """
    m = Model(
        "Valley_TeleportPad",
        "ground centre; pad top y = 1.0; arrows +Z (toward the plot); Label front face z = 5.97 faces -Z; Accent tinted",
        budget=1500,
    )
    base = m.piece("Base", STONE)
    accent = m.piece("Accent", AMBER, tinted=True)
    top = m.piece("Top", SAND)
    poles = m.piece("Poles", BAMBOO)
    label = m.piece("Label", CREAM)
    leaves = m.piece("Leaves", FERN)
    ring(base, 0.0, 5.4, 0.0, 0.5, 20, chamfer=0.15)
    ring(top, 0.0, 4.4, 0.5, 0.85, 20, chamfer=0.1)
    ring(accent, 4.4, 5.3, 0.5, 1.0, 20, chamfer=0.1)
    # Three dino footprints walking toward the plot (+Z): pad + three toes, in the accent colour.
    for i, zc in enumerate((-2.2, 0.2, 2.6)):
        xc = -0.9 if i % 2 == 0 else 0.9
        ellipsoid(accent, (xc, 0.9, zc), (0.75, 0.08, 0.9), rings=3, segments=8)
        for t in (-1, 0, 1):
            ellipsoid(accent, (xc + t * 0.55, 0.9, zc + 1.05 - abs(t) * 0.2), (0.24, 0.07, 0.36), rings=3, segments=6)
    # Signpost: bamboo poles, tinted frame round the Label (board top y 9.0 like Hub_TeleportPad).
    for x in (-4.0, 4.0):
        block(base, (x, 0.3, 6.6), (1.4, 0.6, 1.4), bevel=0.12)
        cylinder(poles, (x, 0.6, 6.6), (x, 9.6, 6.6), 0.42, segments=8)
        for y in (3.0, 6.0):
            cylinder(accent, (x, y - 0.12, 6.6), (x, y + 0.12, 6.6), 0.5, segments=8)
    block(accent, (0.0, 7.4, 6.6), (8.6, 3.2, 0.6), bevel=0.12)
    block(label, (0.0, 7.4, 6.12), (7.3, 2.6, 0.3), bevel=0.05)
    # Leaf ring round the pad foot.
    for k in range(6):
        a = TAU * k / 6 + 0.5
        fern(leaves, (math.cos(a) * 5.9, 0.0, math.sin(a) * 5.9 - (1.0 if math.sin(a) > 0.5 else 0.0)), size=0.6, seed=k, fronds=3)
    return m


def build_egg_stand():
    """
    Nest stand for a Dino egg: mossy stone plinth, a round twig nest (cradle top y 4.0, the egg's
    pivot), bamboo posts holding the log-framed `Sign` behind the egg (front face z = 2.72), a
    tinted bone crest. Same anchor numbers as Hub_EggStand.
    """
    m = Model(
        "Valley_EggStand",
        "ground centre; egg pivot at (0, 4.0, 0); Sign front face (z = 2.72) faces -Z; Accent tinted",
        budget=2500,
    )
    base = m.piece("Base", STONE)
    moss = m.piece("Moss", MOSS)
    nest = m.piece("Nest", BARK)
    accent = m.piece("Accent", AMBER, tinted=True)
    frame = m.piece("Frame", LOG)
    sign = m.piece("Sign", CREAM)
    block(base, (0.0, 0.4, 0.0), (8.4, 0.8, 8.4), bevel=0.3, segments=2)
    ring(base, 0.0, 2.4, 0.8, 3.2, 16, chamfer=0.2)
    ellipsoid(moss, (0.0, 3.1, 0.0), (2.5, 0.3, 2.5), rings=3, segments=10)
    # Twig nest: a torus of crossing sticks round the cradle (top y ~ 4.4), egg sits at y 4.0.
    for k in range(14):
        a = TAU * k / 14
        b = a + 1.1
        p0 = (math.cos(a) * 2.6, 3.3 + 0.35 * (k % 2), math.sin(a) * 2.6)
        p1 = (math.cos(b) * 2.6, 4.1 - 0.35 * (k % 2), math.sin(b) * 2.6)
        cylinder(nest, p0, p1, 0.26, segments=5)
    ring(accent, 2.2, 2.9, 3.0, 3.4, 16, chamfer=0.1)
    # Poles run past the frame (top 13.6): their caps never share the sign panel's top plane (R18).
    for x in (-4.6, 4.6):
        cylinder(frame, (x, 0.8, 2.9), (x, 13.6, 2.9), 0.45, segments=8)
    sign_frame(frame, sign, (0.0, 11.4, 2.9), (9.6, 3.6), border=0.4, depth=0.5)
    cartoon_bone(accent, (-2.8, 13.9, 2.9), (2.8, 13.9, 2.9), 0.32, knob=0.55, segments=8)
    return m


def build_leaderboard():
    """
    Stone tablet leaderboard: slate `Screen` (12.8 x 17.8, front face z = -0.25 at y 12.9) inside a
    tinted `Frame`, boulder feet, a moss cap and an amber trophy-egg on top. Same Screen numbers
    as Hub_Leaderboard (the leaderboard service sizes its SurfaceGui from them).
    """
    m = Model("Valley_Leaderboard", "ground centre; Screen front face (12.8 x 17.8) at z = -0.25 faces -Z; Frame tinted", budget=2500)
    base = m.piece("Base", STONE)
    dark = m.piece("Dark", STONE_DARK)
    frame = m.piece("Frame", AMBER, tinted=True)
    screen = m.piece("Screen", SLATE)
    moss = m.piece("Moss", MOSS)
    trophy = m.piece("Trophy", AMBER_GLOW)
    block(dark, (0.0, 0.6, 0.2), (17.0, 1.2, 4.2), bevel=0.4, segments=2)
    for x in (-6.4, 6.4):
        boulder(base, (x, 2.2, 0.4), (1.6, 1.5, 1.6), seed=int(x * 3) + 50)
    cy = 12.9
    # Tablet slab behind the screen: its front face (z = -0.15) sits 0.1 behind the Screen's (R18).
    block(base, (0.0, cy, 0.55), (15.6, 20.6, 1.4), bevel=0.5, segments=2)
    block(screen, (0.0, cy, 0.0), (12.8, 17.8, 0.5), bevel=0.05)
    for y in (cy - 9.3, cy + 9.3):
        block(frame, (0.0, y, -0.05), (14.4, 0.8, 0.7), bevel=0.12)
    for x in (-6.8, 6.8):
        block(frame, (x, cy, -0.05), (0.8, 19.4, 0.7), bevel=0.12)
    ellipsoid(moss, (0.0, cy + 10.4, 0.45), (7.4, 0.6, 1.0), rings=3, segments=10)
    # Trophy: a golden amber egg in a little bone cup.
    revolve(trophy, [(0.0, 0.0), (1.2, 0.0), (1.2, 0.3), (0.4, 0.6), (0.4, 1.2), (1.4, 1.6), (0.0, 1.6)], center=(0.0, cy + 10.8, 0.45), segments=12)
    ellipsoid(trophy, (0.0, cy + 13.6, 0.45), (1.3, 1.7, 1.3), rings=6, segments=12)
    return m


# =================================================================================================
# Plot frame (plot-local)
# =================================================================================================


def build_plot_ground():
    """Jungle plates either side of the path corridor (|x| <= 10), top y = 0, curved front, back z 312."""
    m = Model("Valley_PlotGround", "plot-local origin (entrance centre on the ring path); top y = 0", budget=600)
    ground = m.piece("Ground", PLOT_FLOOR)
    slab(ground, band_outline(-PLOT_HALF, -CURB_HALF, PLOT_LEN), -1.0, 0.0, chamfer=0.3)
    slab(ground, band_outline(CURB_HALF, PLOT_HALF, PLOT_LEN), -1.0, 0.0, chamfer=0.3)
    return m


def build_path():
    """
    The plot's sandy path: sand |x| <= 8 (top 0.06, z 0..312.6), stone edging 8 <= |x| <= 10 (top
    0.4, from z -0.1 over the ring path mouth), stepping-stone tiles down the middle (top 0.12).
    """
    m = Model("Valley_Path", "plot-local origin; sand |x| <= 8 top 0.06; edging to |x| = 10 (top 0.4)", budget=2500)
    sand = m.piece("Sand", SAND)
    edging = m.piece("Edging", STONE_DARK)
    tiles = m.piece("Tiles", STONE)
    slab(sand, rect_outline(-ROAD_HALF, ROAD_HALF, 0.0, PLOT_LEN + 0.6), -1.0, RING_TOP, chamfer=0.04)
    for x0, x1 in ((-CURB_HALF, -ROAD_HALF), (ROAD_HALF, CURB_HALF)):
        slab(edging, rect_outline(x0, x1, -0.1, PLOT_LEN), -1.0, 0.4, chamfer=0.12)
    z = 6.0
    i = 0
    while z < PLOT_LEN - 4.0:
        x = -2.6 if i % 2 == 0 else 2.6
        block(tiles, (x, RING_TOP + 0.03, z), (4.2, 0.1, 3.4), bevel=0.03)
        z += 7.0
        i += 1
    return m


def build_fern_hedge():
    """
    Low leafy hedge round the sides and back, just OUTSIDE the plot footprint (x = +-[80.2, 82.6],
    z = [312.2, 314.6]) on a log curb, with plot-coloured blossoms (`Blossoms`, TINTED).
    """
    m = Model("Valley_FernHedge", "plot-local origin; hedge x = +-[80.2, 82.6], z = [312.2, 314.6], top y ~ 2.6", budget=2500)
    hedge = m.piece("Hedge", FERN_DARK)
    curb = m.piece("Curb", LOG)
    blossoms = m.piece("Blossoms", PINK, tinted=True)
    z0 = front_z(PLOT_HALF) + 1.2
    side_len = PLOT_LEN + 2.4 - z0
    for x in (-81.4, 81.4):
        block(curb, (x, 0.35, z0 + side_len / 2), (2.6, 0.9, side_len), bevel=0.2)
        block(hedge, (x, 1.6, z0 + side_len / 2), (2.4, 2.0, side_len - 0.4), bevel=0.7, segments=2)
    block(curb, (0.0, 0.35, 313.4), (165.4, 0.9, 2.6), bevel=0.2)
    block(hedge, (0.0, 1.6, 313.4), (165.0, 2.0, 2.4), bevel=0.7, segments=2)
    spots = [(x, z) for x in (-81.4, 81.4) for z in lin(z0 + 3.0, 310.0, 30)]
    spots += [(x, 313.4) for x in lin(-76.0, 76.0, 16)]
    for i, (x, z) in enumerate(spots):
        box(blossoms, (x + (_hash(i, 1.0) - 0.5) * 1.0, 2.62, z), (0.8, 0.3, 0.8))
    return m


def build_entrance_arch():
    """
    Valley plot entrance arch: stacked mossy boulder pillars at x = +-13 (5 x 5 footprint like
    Plot_EntranceArch), a log beam carrying the cream `OwnerSign` panels on both faces, tinted bands
    (`Accent`), a bone crest and a pebble nuke on top with a small amber Neon band.
    """
    m = Model(
        "Valley_EntranceArch",
        "plot-local (0, 0, 4) on the ground; OwnerSign panels: Front face z = -2.0 (toward Base Camp), Back z = +2.0",
        budget=3500,
    )
    stone = m.piece("Stone", STONE)
    dark = m.piece("Dark", STONE_DARK)
    moss = m.piece("Moss", MOSS)
    beam = m.piece("Beam", LOG)
    accent = m.piece("Accent", AMBER, tinted=True)
    sign = m.piece("OwnerSign", CREAM)
    crest = m.piece("Crest", BONE, material="StudsSmall")
    band = m.piece("Band", AMBER_GLOW, material="Neon")
    leaves = m.piece("Leaves", FERN)
    for sx in (-1, 1):
        x = sx * 13.0
        y = 0.0
        for i, (w, h) in enumerate(((5.0, 4.0), (4.5, 4.4), (4.2, 4.2), (3.9, 3.6))):
            block(dark if i % 2 == 0 else stone, (x, y + h / 2, 0.0), (w, h, w), bevel=0.5, segments=2)
            y += h - 0.02
        for yb in (4.0, 12.4):
            block(accent, (x, yb, 0.0), (w + 0.5, 0.7, w + 0.5), bevel=0.15)
        block(moss, (x, 16.4, 0.0), (4.4, 0.6, 4.4), bevel=0.25, segments=2)
        fern(leaves, (x + sx * 3.0, 0.0, -1.5), size=1.1, seed=20 + (sx > 0), fronds=5)
    # Log beam (x +-15.5) with the owner sign boards on both faces.
    log(beam, (-15.6, 17.3, -0.9), (15.6, 17.3, -0.9), 1.15, segments=10)
    log(beam, (-15.6, 17.3, 0.9), (15.6, 17.3, 0.9), 1.15, segments=10)
    log(beam, (-15.0, 19.4, 0.0), (15.0, 19.4, 0.0), 0.9, segments=10)
    for z in (-1.85, 1.85):
        block(sign, (0.0, 17.3, z), (22.0, 3.6, 0.3), bevel=0.06)
    cartoon_bone(crest, (-4.8, 20.75, 0.0), (4.8, 20.75, 0.0), 0.42, knob=0.72, segments=8)
    pebble_nuke(stone, band, dark, (0.0, 21.2, 0.0), height=3.6)
    return m


def build_locked_slot():
    """
    'Coming soon' placeholder for a locked Dino slot: a bamboo fence across the slot front, a
    vine-covered log-framed board (`Sign`, the SurfaceGui face at z = 4.19 like Plot_LockedSlot),
    three giant speckled eggs in a twig nest waiting to hatch, and a few ferns.
    """
    m = Model(
        "Valley_LockedSlot",
        "SLOT-local origin (road-side edge midpoint, +Z away from the road); Sign front z = 4.19 faces the road",
        budget=2000,
    )
    poles = m.piece("Poles", BAMBOO)
    rails = m.piece("Rails", LOG)
    sign = m.piece("Sign", CREAM)
    vines = m.piece("Vines", FERN)
    eggs = m.piece("Eggs", CREAM)
    spots = m.piece("Spots", AMBER)
    nest = m.piece("Nest", BARK)
    xs = lin(-48.0, 48.0, 8)
    for x in xs:
        cylinder(poles, (x, 0.0, 3.0), (x, 4.2, 3.0), 0.42, segments=6)
    for y in (1.6, 3.2):
        for k in range(8):
            cylinder(rails, (xs[k] + 0.3, y, 2.6), (xs[k + 1] - 0.3, y, 2.6), 0.24, segments=5)
    # "COMING SOON" board on bamboo legs (same panel numbers as Plot_LockedSlot).
    sign_frame(rails, sign, (0.0, 9.2, 4.4), (14.0, 5.0), border=0.5, depth=0.6, posts=0.7, post_piece=poles)
    for i, x in enumerate(lin(-6.5, 6.5, 4)):
        path = [(x, 11.9, 4.0), (x + 0.4, 10.6 - 0.6 * (i % 2), 3.95), (x - 0.3, 9.4 - 0.8 * (i % 2), 4.0)]
        tube(vines, path, 0.14, sides=4)
        ellipsoid(vines, path[-1], (0.45, 0.3, 0.12), rings=3, segments=6)
    # Nest of giant eggs inside the slot.
    for k in range(12):
        a = TAU * k / 12
        cylinder(nest, (math.cos(a) * 4.6 - 20.0, 0.4, math.sin(a) * 4.6 + 28.0), (math.cos(a + 1.0) * 4.6 - 20.0, 1.2, math.sin(a + 1.0) * 4.6 + 28.0), 0.4, segments=5)
    for i, (x, z, s) in enumerate(((-21.4, 27.2, 1.0), (-18.4, 28.8, 0.9), (-20.2, 30.0, 0.8))):
        ellipsoid(eggs, (x, 2.1 * s + 0.2, z), (1.6 * s, 2.1 * s, 1.6 * s), rings=6, segments=10)
        for j in range(4):
            a = TAU * j / 4 + i
            ellipsoid(spots, (x + math.cos(a) * 1.45 * s, 2.3 * s + 0.2, z + math.sin(a) * 1.45 * s), (0.36, 0.42, 0.12), rings=3, segments=5)
    for k, (x, z) in enumerate(((26.0, 30.0), (34.0, 22.0), (-34.0, 40.0))):
        fern(vines, (x, 0.0, z), size=1.4, seed=60 + k, fronds=5)
    return m


# =================================================================================================
# Scenery
# =================================================================================================


def build_palm():
    """Cartoon palm (~15 tall) with coconuts and a fern at its foot."""
    m = Model("Valley_Palm", "ground centre; crown ~ (lean) y 15", budget=900)
    trunk = m.piece("Trunk", LOG)
    leaves = m.piece("Leaves", FERN)
    nuts = m.piece("Nuts", BARK)
    palm(trunk, leaves, (0.0, 0.0, 0.0), height=15.0, seed=3, lean=10.0, leaf_count=7, nuts=nuts)
    fern(leaves, (0.0, 0.0, 0.0), size=1.0, seed=8, fronds=5)
    return m


def build_fern():
    """Big fern clump (two layers of fronds), ~3 tall, ~6 across."""
    m = Model("Valley_Fern", "ground centre; ~6 studs across", budget=600)
    light = m.piece("Leaves", FERN)
    dark = m.piece("LeavesDark", FERN_DARK)
    fern(dark, (0.0, 0.0, 0.0), size=1.5, seed=11, fronds=7)
    fern(light, (0.3, 0.2, -0.2), size=1.0, seed=12, fronds=5)
    return m


def build_boulder():
    """Mossy boulder cluster (one big + two small rocks), ~5 tall."""
    m = Model("Valley_Boulder", "ground centre; ~9 x 5 x 7", budget=600)
    rock = m.piece("Rock", STONE)
    dark = m.piece("RockDark", STONE_DARK)
    moss = m.piece("Moss", MOSS)
    boulder(rock, (0.0, 1.9, 0.0), (3.4, 3.0, 2.9), seed=71, rings=5, segments=9)
    boulder(dark, (3.6, 0.9, 1.2), (1.6, 1.2, 1.5), seed=72)
    boulder(dark, (-3.2, 0.7, -1.0), (1.3, 1.0, 1.2), seed=73)
    ellipsoid(moss, (-0.3, 4.4, 0.2), (2.4, 0.5, 2.0), rings=3, segments=9)
    return m


def build_hill():
    """Grassy hill (~40 x 30, ~13 tall) with moss terraces and a boulder."""
    m = Model("Valley_Hill", "ground centre; ~40 x 30, top y ~ 13", budget=1200)
    grass = m.piece("Grass", MEADOW)
    moss = m.piece("Moss", MOSS)
    rock = m.piece("Rock", STONE)
    ellipsoid(grass, (0.0, 0.0, 0.0), (20.0, 13.0, 15.0), rings=6, segments=16, deform=lambda x, y, z: (x, max(y, -1.0), z))
    ellipsoid(moss, (2.0, 9.5, 1.0), (9.0, 3.6, 7.0), rings=4, segments=12)
    boulder(rock, (-9.0, 4.0, -6.0), (2.6, 2.0, 2.2), seed=81)
    return m


def build_fossil_decor():
    """
    Fossil dig decor (kid-friendly: bones and a shell, never a skull): three giant cartoon bones
    half dug out of a sand mound, a big amber-banded ammonite spiral shell, a little dig flag.
    """
    m = Model("Valley_FossilDecor", "ground centre; ~16 x 12; front -Z", budget=2000)
    sand = m.piece("Sand", SAND_DARK)
    bones = m.piece("Bones", BONE, material="StudsSmall")
    shell = m.piece("Shell", AMBER)
    flag = m.piece("Flag", PINK)
    pole = m.piece("Pole", LOG)
    ellipsoid(sand, (0.0, 0.0, 0.0), (8.5, 1.8, 6.0), rings=4, segments=12, deform=lambda x, y, z: (x, max(y, -0.5), z))
    cartoon_bone(bones, (-6.0, 1.2, -1.0), (1.0, 2.6, -3.0), 0.55, knob=0.95, segments=8)
    cartoon_bone(bones, (-2.0, 1.4, 2.5), (5.5, 1.0, 0.5), 0.5, knob=0.9, segments=8)
    cartoon_bone(bones, (2.0, 1.6, -3.5), (6.5, 3.4, -1.0), 0.45, knob=0.8, segments=8)
    # Ammonite: a flat spiral tube standing up.
    spiral = []
    for t in lin(0.0, 1.0, 16):
        a = TAU * 2.0 * t
        r = 0.4 + 2.4 * t
        spiral.append((-3.5 + math.cos(a) * r, 3.3 + math.sin(a) * r, 3.4))
    tube(shell, spiral, 0.5, sides=6, radii=[0.25 + 0.65 * t for t in lin(0.0, 1.0, 16)])
    cylinder(pole, (6.8, 0.0, 3.0), (6.8, 6.5, 3.0), 0.16, segments=5)
    prism(flag, [(6.8, 6.4, 3.0), (6.8, 5.0, 3.0), (8.9, 5.7, 3.0)], (0, 0, 1), 0.08)
    return m


def build_waterfall():
    """
    Waterfall for the cliff ring: a rock notch (two buttresses + lip) with a water sheet falling
    from y ~44 into a round pool with foam, rocks and ferns. Placed against the boundary cliffs,
    front (-Z) toward Base Camp; pool centre at (0, 0, -6).
    """
    m = Model("Valley_Waterfall", "ground centre at the cliff foot; front -Z; pool centre (0, 0, -6)", budget=2500)
    rock = m.piece("Rock", CLIFF)
    dark = m.piece("RockDark", CLIFF_DARK)
    water = m.piece("Water", WATER, material="Smooth")
    foam = m.piece("Foam", FOAM, material="Smooth")
    moss = m.piece("Moss", MOSS)
    for sx in (-1, 1):
        for i, (y, rx, ry) in enumerate(((8.0, 7.0, 9.0), (22.0, 6.0, 9.0), (36.0, 5.4, 8.0))):
            boulder(rock if i % 2 == 0 else dark, (sx * 11.0, y, 6.0), (rx, ry, 6.0), seed=90 + i + (sx > 0) * 5, rings=4, segments=8)
        ellipsoid(moss, (sx * 11.0, 44.5, 6.0), (5.0, 1.2, 5.5), rings=3, segments=8)
    block(dark, (0.0, 42.5, 7.0), (14.0, 4.0, 8.0), bevel=0.8, segments=2)
    # Falling sheet (slightly curved forward at the top) + splash foam.
    loft(
        water,
        [
            [(-4.5, 44.0, 2.4), (4.5, 44.0, 2.4), (4.5, 44.6, 3.4), (-4.5, 44.6, 3.4)],
            [(-4.8, 30.0, 1.0), (4.8, 30.0, 1.0), (4.8, 30.0, 1.8), (-4.8, 30.0, 1.8)],
            [(-5.2, 1.2, 0.2), (5.2, 1.2, 0.2), (5.2, 1.2, 1.0), (-5.2, 1.2, 1.0)],
        ],
    )
    ring(water, 0.0, 11.0, -0.4, 0.5, 24, chamfer=0.0, center=(0.0, -6.0))
    ring(rock, 11.0, 13.0, -0.4, 1.2, 24, chamfer=0.25, center=(0.0, -6.0))
    for k in range(5):
        a = -0.9 + 0.45 * k
        ellipsoid(foam, (math.sin(a) * 3.0, 0.75, -0.6 + math.cos(a) * 1.0), (1.6, 0.5, 1.2), rings=3, segments=7)
    fern(moss, (-12.0, 0.0, -10.0), size=1.4, seed=97, fronds=5)
    fern(moss, (12.5, 0.0, -9.0), size=1.2, seed=98, fronds=5)
    return m


def build_boundary_cliffs():
    """
    45° of the mossy boundary cliffs (world-local origin, centred on +Z): an irregular rock wall whose
    foot is at r 652 (just outside the r 650 collision ring) leaning in to r 644 at the top (y 46-58),
    with a moss crest, a back slope to r 700 and two palms on top. Persistent (the valley rim).
    """
    m = Model("Valley_BoundaryCliffs", "world-local origin; 45° arc centred on +Z; foot r 652, top r 644 (y ~ 52)", budget=3000)
    rock = m.piece("Rock", CLIFF)
    dark = m.piece("RockDark", CLIFF_DARK)
    moss = m.piece("Moss", MOSS)
    trunk = m.piece("Trunk", LOG)
    leaves = m.piece("Leaves", FERN)
    half = math.radians(22.5)
    steps = 14
    sections = []
    tops = []
    for i in range(steps + 1):
        a = -half + 2 * half * i / steps
        h = 46.0 + 12.0 * _hash(i % steps, 3.3)  # wrap: both arc ends get the same height
        bulge = 3.0 * (_hash(i % steps, 5.1) - 0.5)
        prof = [
            (CLIFF_FOOT_R, -1.0),
            (CLIFF_FOOT_R - 2.0 + bulge, h * 0.35),
            (CLIFF_TOP_R + bulge, h * 0.8),
            (CLIFF_TOP_R + 2.0, h),
            (CLIFF_TOP_R + 18.0, h + 2.0),
            (700.0, h * 0.6),
            (700.0, -1.0),
        ]
        sections.append([_pt(r, a, y) for r, y in prof])
        tops.append((a, h))
    loft(rock, sections)
    # Darker strata band + moss crest along the top.
    strata = []
    crest = []
    for a, h in tops:
        strata.append([_pt(r, a, y) for r, y in ((CLIFF_FOOT_R - 2.6, h * 0.42), (CLIFF_FOOT_R - 2.8, h * 0.5), (CLIFF_FOOT_R + 1.0, h * 0.5), (CLIFF_FOOT_R + 1.0, h * 0.42))])
        crest.append([_pt(r, a, y) for r, y in ((CLIFF_TOP_R + 1.4, h - 0.2), (CLIFF_TOP_R + 1.6, h + 1.2), (CLIFF_TOP_R + 16.0, h + 3.2), (CLIFF_TOP_R + 16.0, h + 1.4))])
    # Open ribbons (no end caps): a cap would lie on the same radial plane as the rock's end cap and
    # z-fight there (R18); the next arc's ribbon continues seamlessly instead.
    loft(dark, strata, cap_start=False, cap_end=False)
    loft(moss, crest, cap_start=False, cap_end=False)
    # Rock buttresses bulging out of the face ABOVE head height (y >= 14), so nothing a player can
    # walk to ever pokes inside the r 650 collision ring at foot level.
    for k in range(5):
        a = -half + 2 * half * (k + 0.5) / 5 + 0.03 * (_hash(k, 6.2) - 0.5)
        y = 18.0 + 14.0 * _hash(k, 7.4)
        x, _, z = _pt(CLIFF_FOOT_R - 2.5, a, 0.0)
        boulder(dark if k % 2 == 0 else rock, (x, y, z), (9.0, 7.0, 5.0), seed=130 + k, rings=4, segments=8)
    for k, frac in enumerate((0.3, 0.72)):
        a = -half + 2 * half * frac
        h = 46.0 + 12.0 * _hash(int(frac * steps), 3.3)
        x, _, z = _pt(CLIFF_TOP_R + 9.0, a, 0.0)
        palm(trunk, leaves, (x, h, z), height=13.0, seed=120 + k, lean=8.0, leaf_count=6)
    return m


def build_volcano_backdrop():
    """
    Far backdrop (r ~830, low-poly): a friendly smoking volcano with candy-orange "warm jelly" lava
    stripes, a glowing crater lip and puffy smoke clouds. Persistent; front -Z faces Base Camp.
    """
    m = Model("Valley_VolcanoBackdrop", "ground centre; base r ~110, top y ~ 200; front -Z", budget=2500)
    rock = m.piece("Rock", VOLCANO)
    dark = m.piece("RockDark", VOLCANO_DARK)
    lava = m.piece("Lava", LAVA)
    smoke = m.piece("Smoke", SMOKE)
    moss = m.piece("Moss", MOSS)
    revolve(rock, [(0.0, -2.0), (115.0, -2.0), (96.0, 40.0), (62.0, 120.0), (36.0, 190.0), (26.0, 196.0), (0.0, 186.0)], segments=20)
    revolve(dark, [(28.0, 195.6), (37.0, 191.0), (38.5, 196.5), (30.0, 200.0)], segments=20, closed=True)
    revolve(lava, [(0.0, 194.0), (27.0, 194.0), (27.0, 196.5), (0.0, 196.5)], segments=16)
    # Lava stripes down the front (-Z) flank: thin lofted ribbons proud of the slope.
    for k, (a0, w) in enumerate(((-0.25, 5.0), (0.15, 4.0), (0.5, 3.0))):
        ribbon = []
        for t in lin(0.0, 1.0, 5):
            y = 194.0 - 150.0 * t
            r = 36.5 + (96.0 - 36.5) * (1.0 - y / 194.0) ** 0.9 + 0.8
            a = math.pi + a0 + 0.08 * math.sin(t * 6 + k)
            cx, cz = polar(r, a)
            tx, tz = math.cos(a), -math.sin(a)
            ww = w * (0.6 + 0.8 * t)
            ribbon.append([(cx - tx * ww, y, cz - tz * ww), (cx + tx * ww, y, cz + tz * ww), (cx + tx * ww * 0.9, y, cz + tz * ww * 0.9 - 0.0), (cx - tx * ww * 0.9, y, cz - tz * ww * 0.9)])
        # Give the ribbon thickness by pushing the back pair 1.2 toward the axis.
        thick = []
        for sec in ribbon:
            p0, p1, p2, p3 = sec
            inward = Vector((p0[0], 0, p0[2])).normalized() * -1.4
            thick.append([p0, p1, tuple(Vector(p2) + inward), tuple(Vector(p3) + inward)])
        loft(lava, thick)
    puffs = ((0.0, 214.0, 0.0, 30.0), (-26.0, 230.0, 8.0, 24.0), (22.0, 238.0, -6.0, 22.0), (-8.0, 256.0, 2.0, 22.0), (14.0, 270.0, 4.0, 16.0))
    for x, y, z, r in puffs:
        ellipsoid(smoke, (x, y, z), (r, r * 0.9, r), rings=6, segments=12)
    for k in range(6):
        a = TAU * k / 6 + 0.3
        x, z = polar(102.0, a)
        ellipsoid(moss, (x, 8.0, z), (22.0, 10.0, 16.0), rings=3, segments=8)
    return m


BUILDERS = {
    "Valley_Ground": build_ground,
    "Valley_BaseCamp": build_base_camp,
    "Valley_RingPath": build_ring_path,
    "Valley_Trail": build_trail,
    "Valley_BrontoFountain": build_bronto_fountain,
    "Valley_TitleSign": build_title_sign,
    "Valley_TeleportPad": build_teleport_pad,
    "Valley_EggStand": build_egg_stand,
    "Valley_Leaderboard": build_leaderboard,
    "Valley_PlotGround": build_plot_ground,
    "Valley_Path": build_path,
    "Valley_FernHedge": build_fern_hedge,
    "Valley_EntranceArch": build_entrance_arch,
    "Valley_LockedSlot": build_locked_slot,
    "Valley_Palm": build_palm,
    "Valley_Fern": build_fern,
    "Valley_Boulder": build_boulder,
    "Valley_Hill": build_hill,
    "Valley_FossilDecor": build_fossil_decor,
    "Valley_Waterfall": build_waterfall,
    "Valley_BoundaryCliffs": build_boundary_cliffs,
    "Valley_VolcanoBackdrop": build_volcano_backdrop,
}
