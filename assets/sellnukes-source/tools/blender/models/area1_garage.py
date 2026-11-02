"""
area1_garage.py — Area 1 "Garage Lab" set: a cute toy suburban garage where the first pocket nukes
are made (spec §3.1). Every purchase is its own model so each pad builds in separately.

GARAGE-ORIGIN models share one pivot so B5 places them all with the same CFrame:
    pivot = garage floor centre at ground level (y = 0), door opening toward -Z.
    Footprint 28 (x) x 24 (z); floor top y = 0.6; walls 1 thick, tops at y = 12.6.
        Garage_Floor      concrete plinth + hazard stripe just inside the door
        Garage_WallBack   back wall (z = +11.5) with a framed window
        Garage_WallSide   +X side wall with window and corner posts; spawn it again rotated 180 deg
                          about Y (same pivot) for the -X side
        Garage_WallFront  front wall with the 18 x 10 door opening and two glowing sconces
        Garage_Roof       gable roof (ridge along Z), gables, sign board ("Sign" piece, front face
                          takes a SurfaceGui with the area name), glowing vent stack
        Garage_Door       roll-up door, parked OPEN (bottom edge at y = 7.5): players walk under it

PROP models (pivot = their own ground centre, front toward -Z), with suggested garage placement:
        Workbench     producer "Pocket Nuke Workbench" (10 x 3.3 x 4.2)   at (-4, 0.6, 6), yaw 0
        MiniReactor   bubbling reactor jar ON the bench top              at Workbench pivot + (2.6, 3.3, 0.2)
        ToolWall      pegboard + tool chest against the back wall        at (8, 0.6, 11), yaw 0
        GlowLamp      hazard-footed lamp with a glowing green bulb       at (+-11, 0.6, -6)
        PaintStation  booth with turntable, paint cans and splats        at (-10.5, 0.6, -2), yaw -90
        Driveway      concrete drive + curbs + mailbox, outside the door at garage pivot + (0, 0, -24)

Budgets: shell pieces <= 1,500 triangles, roof <= 2,500, machines/furniture <= 3,000.
Colours come from snkit.core (candy palette). All big faces carry the "Studs" material.
"""

import math

from snkit.core import (
    CHARCOAL,
    CONCRETE,
    CORAL,
    CREAM,
    DARK_STEEL,
    DEEP_BLUE,
    GLASS,
    GLOW_GREEN,
    GLOW_LIGHT,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LAMP_WARM,
    LEAF,
    Model,
    PEGBOARD,
    SIDEWALK,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    WHITE,
    WOOD,
    WOOD_DARK,
    YELLOW,
)
from snkit.kit import block, disc, hazard_band, hazard_floor, hazard_ring, pipe, sign_frame, trefoil
from snkit.shapes import bar, box, cylinder, ellipsoid, prism, revolve, rot_x, rot_y, rot_z

# Garage dimensions (see module doc).
W = 28.0
D = 24.0
FLOOR = 0.6
WALL_T = 1.0
WALL_TOP = 12.6
DOOR_W = 18.0
DOOR_TOP = 10.6
GARAGE_PIVOT = "garage floor centre at ground (y = 0); door opening toward -Z"


# Z-fight layer rule (owner R18, docs/areas-art.md): no two pieces may share a face plane. Trim
# is nudged by ZF (0.05 studs) off every wall face it touches.
ZF = 0.05


def _trim_caps(trim, center_xz, length, axis, cap_extra=0.4):
    """
    Chamfered white cap on a wall top + baseboard (hide the wall blocks' sharp edges).
    Baseboard ends stop ZF short of the wall ends; `cap_extra` lets side walls end their caps
    where the front/back caps begin (no overlapping coplanar cap tops at the corners).
    """
    cx, cz = center_xz
    if axis == "x":
        block(trim, (cx, WALL_TOP + 0.3, cz), (length + cap_extra, 0.6, WALL_T + 0.4), bevel=0.15)
        block(trim, (cx, FLOOR + 0.4, cz), (length - 2 * ZF, 0.8, WALL_T + 0.2), bevel=0.1)
    else:
        block(trim, (cx, WALL_TOP + 0.3, cz), (WALL_T + 0.4, 0.6, length + cap_extra), bevel=0.15)
        block(trim, (cx, FLOOR + 0.4, cz), (WALL_T + 0.2, 0.8, length - 2 * ZF), bevel=0.1)


def _window(trim, glass, center, width, height, axis):
    """Framed window in a wall plane: glass pane, chunky frame, sill and a cross mullion."""
    cx, cy, cz = center
    t = 0.45
    depth = WALL_T + 0.35
    if axis == "x":  # wall runs along X, window faces +/-Z
        box(glass, (cx, cy, cz), (width, height, 0.2))
        # Frame members overlap the opening by ZF so no face lies on a wall-block face (R18).
        block(trim, (cx, cy + height / 2 + t / 2 - ZF, cz), (width + 2 * t, t, depth), bevel=0.1)
        block(trim, (cx, cy - height / 2 - t / 2 + ZF, cz), (width + 2 * t + 0.6, t, depth + 0.5), bevel=0.1)
        for s in (-1, 1):
            block(trim, (cx + s * (width / 2 + t / 2 - ZF), cy, cz), (t, height - 2 * ZF, depth), bevel=0.1)
        block(trim, (cx, cy, cz), (width, 0.22, 0.5), bevel=0.04)
        block(trim, (cx, cy, cz), (0.22, height, 0.5), bevel=0.04)
    else:  # wall runs along Z, window faces +/-X
        box(glass, (cx, cy, cz), (0.2, height, width))
        block(trim, (cx, cy + height / 2 + t / 2 - ZF, cz), (depth, t, width + 2 * t), bevel=0.1)
        block(trim, (cx, cy - height / 2 - t / 2 + ZF, cz), (depth + 0.5, t, width + 2 * t + 0.6), bevel=0.1)
        for s in (-1, 1):
            block(trim, (cx, cy, cz + s * (width / 2 + t / 2 - ZF)), (depth, height - 2 * ZF, t), bevel=0.1)
        block(trim, (cx, cy, cz), (0.5, 0.22, width), bevel=0.04)
        block(trim, (cx, cy, cz), (0.5, height, 0.22), bevel=0.04)


# ------------------------------------------------------------------------------------------------
# Shell (garage-origin pivot)
# ------------------------------------------------------------------------------------------------


def build_floor():
    m = Model("Garage_Floor", GARAGE_PIVOT, budget=1500)
    block(m.piece("Slab", CONCRETE), (0, FLOOR / 2, 0), (W + 0.6, FLOOR, D + 0.6), bevel=0.18)
    # Hazard stripe across the threshold, just inside the door (raised 0.06 to avoid z-fighting).
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    hazard_floor(yellow, black, (0, FLOOR + 0.03, -D / 2 + 2.0), (DOOR_W - 1.0, 1.6), 0.08, stripe=0.8)
    return m


def build_wall_back():
    m = Model("Garage_WallBack", GARAGE_PIVOT, budget=1500)
    wall = m.piece("Wall", SKY_BLUE)
    trim = m.piece("Trim", WHITE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    z = D / 2 - WALL_T / 2
    win_w, win_bottom, win_top = 7.0, 5.6, 9.6
    box(wall, (0, (FLOOR + win_bottom) / 2, z), (W, win_bottom - FLOOR, WALL_T))
    box(wall, (0, (win_top + WALL_TOP) / 2, z), (W, WALL_TOP - win_top, WALL_T))
    side_w = (W - win_w) / 2
    for s in (-1, 1):
        box(wall, (s * (win_w / 2 + side_w / 2), (win_bottom + win_top) / 2, z), (side_w, win_top - win_bottom, WALL_T))
    _trim_caps(trim, (0, z), W, "x")
    _window(trim, glass, (0, (win_bottom + win_top) / 2, z), win_w, win_top - win_bottom, "x")
    return m


def build_wall_side():
    m = Model("Garage_WallSide", GARAGE_PIVOT + "; this is the +X wall (rotate 180 for -X)", budget=1500)
    wall = m.piece("Wall", SKY_BLUE)
    trim = m.piece("Trim", WHITE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    x = W / 2 - WALL_T / 2
    inner = D - 2 * WALL_T  # side walls sit between the front and back walls
    win_c, win_w, win_bottom, win_top = 4.0, 5.0, 5.6, 9.1
    box(wall, (x, (FLOOR + win_bottom) / 2, 0), (WALL_T, win_bottom - FLOOR, inner))
    box(wall, (x, (win_top + WALL_TOP) / 2, 0), (WALL_T, WALL_TOP - win_top, inner))
    front_len = (win_c - win_w / 2) - (-inner / 2)
    back_len = inner / 2 - (win_c + win_w / 2)
    box(wall, (x, (win_bottom + win_top) / 2, -inner / 2 + front_len / 2), (WALL_T, win_top - win_bottom, front_len))
    box(wall, (x, (win_bottom + win_top) / 2, inner / 2 - back_len / 2), (WALL_T, win_top - win_bottom, back_len))
    # Side caps stop where the front/back caps start (no overlapping coplanar tops, R18).
    _trim_caps(trim, (x, 0), inner, "z", cap_extra=-0.4)
    _window(trim, glass, (x, (win_bottom + win_top) / 2, win_c), win_w, win_top - win_bottom, "z")
    # Chunky corner posts on both corners of this side (the mirrored copy covers the other two);
    # they rise 0.15 above the caps so their tops never share the cap plane.
    post_top = WALL_TOP + 0.75
    for z in (-D / 2 + 0.5, D / 2 - 0.5):
        block(trim, (W / 2 - 0.5, (FLOOR + post_top) / 2, z), (1.5, post_top - FLOOR, 1.5), bevel=0.2)
    return m


def build_wall_front():
    m = Model("Garage_WallFront", GARAGE_PIVOT, budget=1500)
    wall = m.piece("Wall", SKY_BLUE)
    trim = m.piece("Trim", WHITE)
    z = -D / 2 + WALL_T / 2
    pillar_w = (W - DOOR_W) / 2
    for s in (-1, 1):
        box(wall, (s * (DOOR_W / 2 + pillar_w / 2), (FLOOR + WALL_TOP) / 2, z), (pillar_w, WALL_TOP - FLOOR, WALL_T))
    box(wall, (0, (DOOR_TOP + WALL_TOP) / 2, z), (DOOR_W, WALL_TOP - DOOR_TOP, WALL_T))
    block(trim, (0, WALL_TOP + 0.3, z), (W + 0.4, 0.6, WALL_T + 0.4), bevel=0.15)
    for s in (-1, 1):
        block(trim, (s * (DOOR_W / 2 + pillar_w / 2), FLOOR + 0.4, z), (pillar_w - 2 * ZF, 0.8, WALL_T + 0.2), bevel=0.1)
        # Door jambs reach ZF into the opening (no face on the pillar's inner face, R18).
        block(trim, (s * (DOOR_W / 2 + 0.3 - ZF), (FLOOR + DOOR_TOP) / 2, z), (0.6, DOOR_TOP - FLOOR, WALL_T + 0.4), bevel=0.1)
    block(trim, (0, DOOR_TOP + 0.3 - ZF, z), (DOOR_W + 1.2, 0.6, WALL_T + 0.4), bevel=0.1)
    # Two wall sconces either side of the door: dark bracket + warm glowing box lamp.
    bracket = m.piece("Brackets", DARK_STEEL)
    lamp = m.piece("Lamps", LAMP_WARM, material="Neon")
    for s in (-1, 1):
        x = s * (DOOR_W / 2 + pillar_w / 2)
        block(bracket, (x, 8.2, z - 0.75), (0.9, 0.3, 0.5), bevel=0.06)
        block(bracket, (x, 9.6, z - 0.75), (0.9, 0.3, 0.5), bevel=0.06)
        block(lamp, (x, 8.9, z - 0.8), (0.7, 1.2, 0.5), bevel=0.12)
    return m


def build_roof():
    m = Model("Garage_Roof", GARAGE_PIVOT, budget=2500)
    roof = m.piece("Roof", CORAL)
    gable = m.piece("Gable", SKY_BLUE)
    trim = m.piece("Trim", WHITE)
    eave_y, eave_x = 12.65, W / 2 + 1.2  # roof edge overhangs the walls by 1.2
    ridge_y = 19.6
    run, rise = eave_x, ridge_y - eave_y
    length = math.hypot(run, rise)
    theta = math.degrees(math.atan2(rise, run))
    thick = 0.9
    roof_len = D + 2.0
    nx, ny = math.sin(math.radians(theta)), math.cos(math.radians(theta))
    for s in (-1, 1):
        mid_x, mid_y = s * run / 2, (eave_y + ridge_y) / 2
        center = (mid_x + s * nx * thick / 2, mid_y + ny * thick / 2, 0)
        rot = rot_z(-theta if s > 0 else theta)
        box(roof, center, (length + 0.2, thick, roof_len), rot=rot, bevel=0.14)
        # Fascia boards on both gable ends of this slope.
        for zs in (-1, 1):
            box(trim, (center[0], center[1], zs * (roof_len / 2 + 0.05)), (length + 0.3, thick + 0.35, 0.3), rot=rot, bevel=0.06)
    block(trim, (0, ridge_y + 0.75, 0), (1.5, 0.7, roof_len + 0.4), bevel=0.18)
    # Gable triangles (front and back) under the slopes.
    for zs in (-1, 1):
        z = zs * (D / 2 - WALL_T / 2)
        outline = [(-W / 2, WALL_TOP, z), (W / 2, WALL_TOP, z), (0, ridge_y - 0.1, z)]
        prism(gable, outline, (0, 0, 1), WALL_T)
    # Sign board on the front gable: the "Sign" panel's front (-Z) face takes the area name.
    sign = m.piece("Sign", CREAM)
    sign_frame(trim, sign, (0, 15.2, -D / 2 - 0.2), (10.0, 2.6), border=0.45, depth=0.5)
    # Vent stack poking out of the +X slope with a glowing green ring (the reactor inside!).
    vent = m.piece("Vent", STEEL)
    glow = m.piece("VentGlow", GLOW_GREEN, material="Neon")
    vx, vz = 7.0, 6.0
    roof_y = eave_y + (eave_x - vx) * (rise / run)
    cylinder(vent, (vx, roof_y - 0.5, vz), (vx, roof_y + 2.6, vz), 0.6, segments=14)
    disc(vent, (vx, roof_y + 3.15, vz), 0.95, 0.35, segments=14, bevel=0.1)
    revolve(glow, [(0.58, -0.25), (0.72, -0.2), (0.72, 0.2), (0.58, 0.25)], center=(vx, roof_y + 2.8, vz), segments=14, closed=True)
    return m


def build_door():
    m = Model("Garage_Door", GARAGE_PIVOT + "; door parked open, bottom edge y = 7.5", budget=1500)
    door = m.piece("Door", WHITE)
    steel = m.piece("Steel", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    z = -D / 2 + WALL_T / 2
    slat = 0.85
    y = DOOR_TOP
    for _ in range(3):
        block(door, (0, y - slat / 2, z), (DOOR_W - 0.3, slat - 0.04, 0.45), bevel=0.14)
        y -= slat
    hazard_band(yellow, black, (0, y - 0.3, z), (DOOR_W - 0.3, 0.6, 0.5), stripe=0.7)
    # Roll housing inside the header, guide rails down both jambs, pull handle.
    block(steel, (0, DOOR_TOP - 0.7, z + 1.3), (DOOR_W + 0.6, 1.4, 1.6), bevel=0.2)
    for s in (-1, 1):
        box(steel, (s * (DOOR_W / 2 - 0.1), (FLOOR + DOOR_TOP) / 2, z + 0.55), (0.35, DOOR_TOP - FLOOR, 0.5))
    bar(steel, (-0.9, y - 0.25, z - 0.4), (0.9, y - 0.25, z - 0.4), 0.18)
    for s in (-1, 1):
        bar(steel, (s * 0.9, y - 0.25, z - 0.4), (s * 0.9, y - 0.25, z - 0.1), 0.16)
    return m


# ------------------------------------------------------------------------------------------------
# Props (own pivot = ground centre, front -Z)
# ------------------------------------------------------------------------------------------------


def build_workbench():
    m = Model("Workbench", "ground centre; work side faces -Z; bench top at y = 3.3", budget=3000)
    top = m.piece("Top", WOOD)
    frame = m.piece("Frame", DARK_STEEL)
    shelf = m.piece("Shelf", WOOD_DARK)
    cabinet = m.piece("Cabinet", TOY_RED)
    drawers = m.piece("Drawers", CORAL)
    steel = m.piece("Steel", STEEL, material="StudsSmall")
    paper = m.piece("Blueprint", SKY_BLUE, material="Smooth")
    block(top, (0, 2.95, 0), (10.0, 0.7, 4.2), bevel=0.2)
    for sx in (-1, 1):
        for sz in (-1, 1):
            # 2.5 tall: tops stay 0.1 under the cabinet / table plane (no shared face, R18).
            block(frame, (sx * 4.3, 1.25, sz * 1.65), (0.7, 2.5, 0.7), bevel=0.1)
    for sz in (-1, 1):
        box(frame, (1.3, 0.65, sz * 1.65), (6.0, 0.35, 0.35))
    box(frame, (4.3, 0.65, 0), (0.35, 0.35, 3.3))
    block(shelf, (1.4, 0.95, 0), (5.8, 0.3, 3.5), bevel=0.08)
    # Red drawer cabinet on the left.
    block(cabinet, (-3.05, 1.3, 0), (3.0, 2.6, 3.7), bevel=0.15)
    for y in (0.75, 1.9):
        block(drawers, (-3.05, y, -1.86), (2.5, 0.95, 0.2), bevel=0.08)
        bar(steel, (-3.6, y + 0.1, -2.05), (-2.5, y + 0.1, -2.05), 0.16)
    # Bench vise on the right front corner.
    block(steel, (4.1, 3.75, -1.45), (1.3, 0.9, 1.2), bevel=0.1)
    block(steel, (4.1, 3.85, -2.2), (1.3, 0.7, 0.35), bevel=0.06)
    cylinder(steel, (4.1, 3.75, -2.35), (4.1, 3.75, -3.1), 0.12, segments=8)
    bar(steel, (3.6, 3.75, -3.1), (4.6, 3.75, -3.1), 0.14)
    # Tools on the top: wrench and a hammer head (steel), blueprint sheet.
    bar(steel, (-1.6, 3.36, -0.9), (0.2, 3.36, -1.4), 0.22)
    block(steel, (-1.75, 3.38, -0.85), (0.5, 0.18, 0.5), bevel=0.05)
    block(steel, (0.35, 3.38, -1.45), (0.5, 0.18, 0.5), bevel=0.05)
    block(steel, (-3.4, 3.5, 0.9), (0.45, 0.45, 1.1), bevel=0.08)
    bar(shelf, (-3.4, 3.42, 0.9), (-1.6, 3.42, 1.2), 0.2)
    box(paper, (-0.9, 3.32, 0.4), (2.4, 0.04, 1.7), rot=rot_y(8))
    return m


def build_mini_reactor():
    m = Model("MiniReactor", "base centre; gauge faces -Z; sits on the Workbench top", budget=3000)
    base = m.piece("Base", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW, material="StudsSmall")
    black = m.piece("HazardBlack", HAZARD_BLACK, material="StudsSmall")
    housing = m.piece("Housing", DEEP_BLUE, material="StudsSmall")
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.5)
    liquid = m.piece("Liquid", GLOW_GREEN, material="Neon")
    bubbles = m.piece("Bubbles", GLOW_LIGHT, material="Neon")
    cap = m.piece("Cap", STEEL, material="StudsSmall")
    gauge = m.piece("Gauge", WHITE, material="Smooth")
    disc(base, (0, 0, 0), 1.4, 0.35, segments=20, bevel=0.1)
    hazard_ring(yellow, black, (0, 0, 0), 1.02, 1.42, 0.33, 0.45, count=12)
    revolve(housing, [(0.0, 0.35), (1.08, 0.35), (1.1, 1.05), (0.95, 1.2), (0.0, 1.2)], segments=20)
    revolve(glass, [(0.0, 1.15), (0.9, 1.15), (0.9, 2.6), (0.72, 2.95), (0.0, 3.0)], segments=20)
    revolve(liquid, [(0.0, 1.2), (0.8, 1.2), (0.8, 2.25), (0.5, 2.36), (0.0, 2.4)], segments=16)
    for x, y, z, r in ((0.3, 1.6, -0.2, 0.18), (-0.35, 1.9, 0.15, 0.14), (0.1, 2.15, 0.35, 0.12),
                       (-0.1, 2.55, -0.1, 0.16), (0.28, 2.75, 0.2, 0.1), (-0.4, 1.45, -0.35, 0.12)):
        ellipsoid(bubbles, (x, y, z), (r, r, r), rings=4, segments=8)
    revolve(cap, [(0.0, 2.9), (0.78, 2.9), (0.82, 3.12), (0.6, 3.3), (0.0, 3.32)], segments=16)
    cylinder(cap, (0, 3.3, 0), (0, 3.6, 0), 0.16, segments=8)
    ellipsoid(cap, (0, 3.68, 0), (0.24, 0.16, 0.24), rings=4, segments=8)
    pipe(cap, [(0.55, 3.15, 0.2), (1.25, 3.15, 0.2), (1.25, 0.95, 0.2), (1.05, 0.95, 0.2)], 0.12, segments=8)
    # Gauge on the housing front (-Z): white face + steel needle.
    revolve(gauge, [(0.0, -0.05), (0.32, -0.05), (0.32, 0.05), (0.0, 0.05)], center=(0, 0.78, -1.12), segments=14, rot=rot_x(90))
    bar(cap, (0, 0.78, -1.2), (0.18, 0.95, -1.2), 0.06)
    return m


def build_tool_wall():
    m = Model("ToolWall", "ground centre of the back (z = 0, flush to a wall); unit faces -Z", budget=3000)
    chest = m.piece("Chest", DEEP_BLUE)
    drawers = m.piece("Drawers", SKY_BLUE)
    steel = m.piece("Steel", STEEL, material="StudsSmall")
    board = m.piece("Board", PEGBOARD)
    frame = m.piece("Frame", WOOD_DARK)
    grips = m.piece("Grips", TOY_RED, material="StudsSmall")
    pegs = m.piece("Pegs", CHARCOAL, material="Smooth")
    sign = m.piece("Sign", HAZARD_YELLOW, material="Smooth")
    mark = m.piece("Trefoil", HAZARD_BLACK, material="Smooth")
    block(chest, (0, 1.6, -1.25), (9.0, 3.2, 2.5), bevel=0.18)
    block(chest, (0, 3.32, -1.25), (9.3, 0.25, 2.7), bevel=0.08)
    for row, y in enumerate((0.6, 1.55, 2.5)):
        for x in (-2.15, 2.15):
            block(drawers, (x, y, -2.52), (4.0, 0.78, 0.16), bevel=0.06)
            bar(steel, (x - 0.6, y, -2.68), (x + 0.6, y, -2.68), 0.14)
    # Pegboard (the stud texture reads as pegboard holes) in a dark wood frame.
    sign_frame(frame, board, (0, 7.0, -0.25), (11.0, 6.6), border=0.5, depth=0.5)
    zf = -0.65  # tool plane in front of the board
    # Hammer
    bar(frame, (-4.0, 5.0, zf), (-4.0, 7.6, zf), 0.3)
    block(steel, (-4.0, 7.8, zf), (1.3, 0.55, 0.45), bevel=0.08)
    # Two wrenches
    for x, top, bot in ((-2.4, 8.6, 5.6), (-1.4, 8.2, 6.1)):
        bar(steel, (x, bot, zf), (x, top, zf), 0.26)
        block(steel, (x, top + 0.2, zf), (0.7, 0.5, 0.3), bevel=0.08)
        block(steel, (x, bot - 0.15, zf), (0.55, 0.4, 0.3), bevel=0.08)
    # Three screwdrivers: red grips + steel shafts
    for i, x in enumerate((0.2, 0.9, 1.6)):
        cylinder(grips, (x, 8.6 - i * 0.2, zf), (x, 7.5 - i * 0.2, zf), 0.24, segments=8)
        cylinder(steel, (x, 7.5 - i * 0.2, zf), (x, 5.8 - i * 0.3, zf), 0.07, segments=6)
    # Saw: steel blade (prism) + red grip
    prism(steel, [(2.8, 5.2, zf), (4.4, 5.2, zf), (4.4, 6.3, zf), (2.8, 7.4, zf)], (0, 0, 1), 0.08)
    block(grips, (2.65, 7.5, zf), (0.6, 1.0, 0.3), bevel=0.1)
    # Pegs the tools hang on
    for x, y in ((-4.0, 8.25), (-2.4, 9.05), (-1.4, 8.65), (0.2, 8.8), (0.9, 8.6), (1.6, 8.4), (2.65, 8.15)):
        cylinder(pegs, (x, y, -0.45), (x, y, -0.95), 0.07, segments=6)
    # Little "glows when it's ready" hazard sign in the top-right corner
    block(sign, (4.2, 9.2, -0.62), (1.6, 1.6, 0.18), bevel=0.12)
    trefoil(mark, (4.2, 9.2, -0.74), 0.6, 0.06)
    return m


def build_glow_lamp():
    m = Model("GlowLamp", "ground centre; bulb centre at y = 5.6", budget=1500)
    post = m.piece("Post", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    bulb = m.piece("Bulb", GLOW_GREEN, material="Neon")
    block(black, (0, 0.12, 0), (2.4, 0.24, 2.4), bevel=0.08)
    hazard_floor(yellow, None, (0, 0.26, 0), (2.4, 2.4), 0.06, stripe=0.45, inset=0.12)
    disc(post, (0, 0.25, 0), 0.75, 0.45, segments=14, bevel=0.12)
    cylinder(post, (0, 0.7, 0), (0, 4.9, 0), 0.2, segments=10)
    # Cage in hazard yellow (merged into the yellow piece: same colour = same draw call).
    disc(yellow, (0, 4.8, 0), 0.8, 0.25, segments=12, bevel=0.08)
    disc(yellow, (0, 6.35, 0), 0.85, 0.3, segments=12, bevel=0.1)
    for a in range(4):
        ang = math.radians(45 + 90 * a)
        x, z = 0.62 * math.cos(ang), 0.62 * math.sin(ang)
        bar(yellow, (x, 5.0, z), (x, 6.4, z), 0.13)
    ellipsoid(bulb, (0, 5.6, 0), (0.5, 0.62, 0.5), rings=6, segments=12)
    ellipsoid(post, (0, 6.75, 0), (0.25, 0.18, 0.25), rings=4, segments=8)
    return m


def _splat(piece, center, radius, seed):
    """Flat cartoon paint splat on a -Z facing wall (deterministic wobbly outline)."""
    cx, cy, cz = center
    pts = []
    for k in range(14):
        a = 2 * math.pi * k / 14
        r = radius * (1 + 0.22 * math.sin(3 * a + seed) + 0.12 * math.cos(5 * a + 2 * seed))
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a), cz))
    prism(piece, pts, (0, 0, 1), 0.08)


def build_paint_station():
    m = Model("PaintStation", "ground centre; open side faces -Z; turntable top at y = 0.5", budget=3000)
    booth = m.piece("Booth", CREAM)
    trim = m.piece("Trim", DEEP_BLUE)
    turntable = m.piece("Turntable", DARK_STEEL)
    rubber = m.piece("Rubber", CHARCOAL)
    lids = m.piece("Lids", STEEL, material="StudsSmall")
    paints = {
        "PaintRed": m.piece("PaintRed", TOY_RED, material="StudsSmall"),
        "PaintYellow": m.piece("PaintYellow", YELLOW, material="StudsSmall"),
        "PaintBlue": m.piece("PaintBlue", SKY_BLUE, material="StudsSmall"),
    }
    # Booth: back + two sides + canopy, with blue edge trim.
    block(booth, (0, 3.3, 2.35), (7.2, 6.2, 0.4), bevel=0.12)
    for s in (-1, 1):
        block(booth, (s * 3.4, 3.3, 0.1), (0.4, 6.2, 4.9), bevel=0.12)
        block(trim, (s * 3.4, 3.3, -2.4), (0.6, 6.4, 0.3), bevel=0.08)
    block(booth, (0, 6.55, 0.1), (7.6, 0.4, 5.3), bevel=0.12)
    block(trim, (0, 6.55, -2.6), (7.8, 0.7, 0.3), bevel=0.08)
    block(rubber, (0, 0.06, 0.1), (6.6, 0.12, 4.6), bevel=0.04)
    # Turntable for the nuke being painted.
    disc(turntable, (0, 0.1, 0.2), 1.6, 0.4, segments=20, bevel=0.1)
    hazard = paints["PaintYellow"]
    revolve(hazard, [(1.3, 0.48), (1.5, 0.48), (1.5, 0.55), (1.3, 0.55)], center=(0, 0, 0.2), segments=20, closed=True)
    # Shelf with three paint cans on the left panel.
    block(booth, (-2.6, 2.4, 0.6), (1.2, 0.2, 3.4), bevel=0.05)
    for i, key in enumerate(("PaintRed", "PaintYellow", "PaintBlue")):
        z = -0.5 + i * 1.1
        cylinder(paints[key], (-2.6, 2.5, z), (-2.6, 3.2, z), 0.38, segments=12)
        disc(lids, (-2.6, 3.2, z), 0.4, 0.1, segments=12, bevel=0.03)
    # Splats on the back wall and drips down it.
    _splat(paints["PaintRed"], (-1.2, 4.2, 2.1), 0.8, 0.3)
    _splat(paints["PaintBlue"], (1.4, 3.4, 2.1), 0.7, 1.7)
    _splat(paints["PaintYellow"], (0.3, 5.1, 2.1), 0.55, 2.9)
    block(paints["PaintRed"], (-1.0, 3.2, 2.1), (0.25, 1.4, 0.08), bevel=0.06)
    block(paints["PaintBlue"], (1.6, 2.6, 2.1), (0.22, 1.0, 0.08), bevel=0.06)
    # Spray gun hanging from the canopy on a hose.
    pipe(rubber, [(1.6, 6.35, 0.6), (1.6, 5.0, 0.4), (1.3, 4.2, -0.4)], 0.09, segments=6)
    block(rubber, (1.3, 4.0, -0.5), (0.35, 0.8, 0.5), bevel=0.06)
    block(lids, (1.3, 4.35, -0.95), (0.3, 0.3, 0.6), bevel=0.05)
    return m


def build_driveway():
    m = Model("Driveway", "ground centre of the drive; top at y = 0.3; garage door at +Z end", budget=1500)
    slab = m.piece("Slab", CONCRETE)
    curbs = m.piece("Curbs", SIDEWALK)
    post = m.piece("MailPost", WOOD_DARK)
    mailbox = m.piece("Mailbox", DEEP_BLUE)
    flag = m.piece("Flag", TOY_RED)
    shrubs = m.piece("Shrubs", LEAF)
    # Four poured sections: the chamfers between them read as expansion joints.
    for i in range(4):
        z = -9.0 + i * 6.0
        block(slab, (0, 0.15, z), (16.0, 0.3, 5.9), bevel=0.12)
    for s in (-1, 1):
        block(curbs, (s * 8.45, 0.3, 0), (0.9, 0.6, 24.0), bevel=0.15)
    # Mailbox at the front-left corner (outside the curb).
    block(post, (-9.9, 1.6, -10.5), (0.45, 3.2, 0.45), bevel=0.06)
    block(mailbox, (-9.9, 3.45, -10.5), (0.95, 0.75, 1.7), bevel=0.08)
    cylinder(mailbox, (-9.9, 3.8, -11.35), (-9.9, 3.8, -9.65), 0.475, segments=12)
    block(flag, (-9.35, 3.9, -10.2), (0.12, 1.0, 0.18), bevel=0.03)
    block(flag, (-9.35, 4.25, -10.45), (0.12, 0.4, 0.5), bevel=0.03)
    # Blocky shrubs either side of the drive mouth.
    for x in (-10.2, 10.2):
        block(shrubs, (x, 0.75, -6.0), (1.8, 1.5, 1.8), bevel=0.35, segments=2)
        block(shrubs, (x, 1.75, -6.0), (1.2, 0.8, 1.2), bevel=0.25, segments=2)
    return m


BUILDERS = {
    "Garage_Floor": build_floor,
    "Garage_WallBack": build_wall_back,
    "Garage_WallSide": build_wall_side,
    "Garage_WallFront": build_wall_front,
    "Garage_Roof": build_roof,
    "Garage_Door": build_door,
    "Workbench": build_workbench,
    "MiniReactor": build_mini_reactor,
    "ToolWall": build_tool_wall,
    "GlowLamp": build_glow_lamp,
    "PaintStation": build_paint_station,
    "Driveway": build_driveway,
}
