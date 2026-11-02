"""
area06.py — Area 6 "Rocket Factory" (spec §3.6): a cartoon toy-rocket factory with a conveyor line,
nodding robot arms, a fin press with a spinning flywheel, a paint booth, a scanner arch, a forklift,
a loading dock served by a drivable delivery semi-truck and the Factory Boss on his mezzanine. Rockets are candy-coloured
space toys (round portholes, chunky fins) — never real weapons. Every pad purchase is its own model
set so each one builds in separately; placement lives in src/shared/Config/AreaLayouts/Area06.luau.

Shared toy helpers (Xf, _hash, toy_figure, SKIN) come from area04.py so every worker / manager
figure across areas 4-6 has the same proportions.

Every model has its OWN pivot (ground centre unless stated, front = -Z). The layout places it with a
slot-local CFrame (slot +Z points away from the road, so identity rotation faces the road); models
standing on the factory floor are placed at y = 0.4 (floor top).

Models (key: pivot / notes)                                         build key
    A6_Floor        slab centre at ground; top y = 0.4; yellow lane lines  base
    A6_EntryArch    ground centre of the walkway opening; double-sided    base
                    "ROCKET / FACTORY" block letters (R17)
    A6_ShellBack    back wall (along X) with two roll-up shutter doors     A6_FactoryShell
                    at local x = +31 / +44 (behind the loading dock); ends
                    INSIDE the side walls' corner columns (R18: one column
                    per corner, owned by A6_ShellSide)
    A6_ShellSide    side wall (along Z), symmetric in z: place it at the   A6_FactoryShell
                    +X edge with yaw 0 and at the -X edge with yaw 180;
                    owns the four corner columns
    A6_RoofFrame    open sawtooth roof frame: girders + glass clerestories A6_FactoryShell
    A6_RocketLine   PRODUCER "Rocket Line": gantry over a big toy rocket   A6_FactoryShell
    A6_Conveyor     belt along local Z (34 long, top y = 3.25)             A6_Conveyor
    A6_ToyRocket    small toy rocket riding the belt (Rocket = tinted)     A6_Conveyor
    A6_RobotArm     pedestal + nodding Arm (hinge at local (0, 8.4, 0))    A6_RobotArms
    A6_FinPress     press frame + ram + spinning flywheel (Wheel)          A6_FinPress
    A6_PaintBooth   open-front booth, rocket on a turntable, vent Fan      A6_PaintBooth
    A6_QualityCheck scanner arch over the belt (tunnel along local X)      A6_QualityCheck
    A6_Forklift     toy forklift carrying a pallet of crates; drivable:    A6_Forklift
                    TyresF/TyresR + HubsF/HubsR (axles z -1.7 / 1.7)
    A6_LoadingDock  raised dock + bumpers + pallets (no truck since R56)   A6_LoadingDock
    A6_DeliveryTruck drivable cab-over semi with a flatbed of 4 crates     A6_LoadingDock (R56,
                    (Cargo1..4), per-axle Tyres/Hubs F/M/R, BrakeLights,   placed by the layout)
                    IndicatorL/R; 14.5 long, pivot ground centre, cab -Z
    A6_FactoryBoss  mezzanine office + boss with a megaphone               A6_FactoryBoss

Animation contract = piece NAMES resolved by src/shared/Config/WorldFxConfig.luau (B4). The client
moves each tagged piece about ITS OWN bounding-box centre with a random phase per piece, so:
    Belt    (A6_Conveyor) scroll: the stud texture moves over the piece's TOP face along local Z.
            The Belt piece is one flat slab whose top face IS the belt surface, running along Z.
    Arm     (A6_RobotArm) oscillate +-22 deg about local X through its bbox centre. The Arm piece is
            point-symmetric about the hinge (gripper hanging down at the front, a counterweight of
            equal extent sticking up at the back), so its bbox centre == hinge (0, 8.4, 0).
    Wheel   (A6_FinPress) spin about local X: the flywheel (rim + 4 spokes + hub) is symmetric about
            the X axis through its bbox centre (local (4.6, 7.0, 0)).
    Fan     (A6_PaintBooth) spin about local Z: 4-blade vent fan facing -Z, centred at (0, 8.9, -5.1).
    Rocket  (A6_ToyRocket body) tiny 0.05-stud vibration on the line.
    Glow    (A6_QualityCheck scan bar) bob +-0.3 + PointLight; free between the posts.
    Bulb    (A6_QualityCheck check mark, A6_RocketLine status light) static + PointLight.
    Neon    static Neon (forklift beacon) — deliberately NOT an FX word. The truck's lamps are
            `Headlights` (Neon), `BrakeLights` / `IndicatorL` / `IndicatorR` (Smooth; R56 vehicle FX).
    Every other piece name is chosen to NOT resolve (no `Crystal`, `Conveyor`, `Lamp`, `Wheel*`,
    `Rocket*` prefixes): the producer's big rocket uses Hull / Nose / Window, the dock's pink rockets use Toys;
    `Cargo1..N` are the truck's per-crate pieces (R56: the client pops them in one by one).

Budgets: shell pieces <= 4,500 triangles, machines <= 4,500, props <= 3,000.
"""

from __future__ import annotations

import math

from snkit.core import (
    CHARCOAL,
    CONCRETE_DARK,
    DARK_STEEL,
    DEEP_BLUE,
    GLASS,
    GLOW_GREEN,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LAMP_WARM,
    LIME,
    Model,
    MINT,
    OFF_WHITE,
    ORANGE,
    PINK,
    PURPLE,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    TYRE,
    WHITE,
    WOOD,
    YELLOW,
)
from snkit.kit import _stripe_polys, block, disc, hazard_band, hazard_floor, hazard_ring, sign_frame, truss
from snkit.shapes import bar, box, clip_convex, cylinder, prism, revolve, rot_x, rot_y, rot_z

from models.area01 import sign_text  # shared double-sided block lettering (owner R17)
from models.area03 import AMBER, axle_wheels  # R56 drivable-vehicle kit (per-axle wheels + hubs)
from models.area04 import SKIN, Xf, toy_figure

# ------------------------------------------------------------------------------------------------
# Area-local palette (the global candy palette lives in snkit/core.py).
# ------------------------------------------------------------------------------------------------

PANEL = (214, 218, 230)  # light grey factory wall panels
FLOOR_GREY = (166, 172, 188)  # factory concrete, a notch darker than the walls so the shell reads
ZONE_GREY = (124, 130, 150)  # machine-zone patches
SCAN_CYAN = (90, 232, 255)  # quality-check scan bar (Neon)

FLOOR_TOP = 0.4  # factory floor top; models standing on the floor are placed at y = FLOOR_TOP
SLOT_W = 104.0
SLOT_D = 70.0
WALL_H = 22.0  # shell wall height (coping on top reaches 22.6)
ROOF_Y = 22.6  # roof frame bottom chords sit on the wall coping


# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------


def toy_rocket(hull, nose, window, base, height: float = 3.2, radius: float = 0.55, segments: int = 12, fin_count: int = 4):
    """
    Upright cartoon space-toy rocket standing on its fins, front (porthole) toward -Z.

    hull:   body piece (the candy colour; may be tinted)
    nose:   nose cone + fins + nozzle + porthole rim (one accent colour = one draw call)
    window: porthole glass disc
    base:   centre under the fins (Roblox space). Returns the model-space top y.

    Example: toy_rocket(m.piece("Rocket", MINT, tinted=True), nose, window, (0, 0, 0), height=3.2)
    """
    bx, by, bz = base
    h, r = height, radius
    y0 = 0.12 * h
    revolve(
        hull,
        [(0.0, y0), (0.7 * r, y0), (0.95 * r, y0 + 0.05 * h), (r, y0 + 0.15 * h), (r * 1.04, 0.42 * h), (r, 0.66 * h), (0.0, 0.66 * h)],
        center=(bx, by, bz),
        segments=segments,
    )
    revolve(
        nose,
        [(0.0, 0.66 * h - 0.02), (1.03 * r, 0.66 * h - 0.02), (0.93 * r, 0.76 * h), (0.62 * r, 0.88 * h), (0.25 * r, 0.97 * h), (0.0, h)],
        center=(bx, by, bz),
        segments=segments,
    )
    # Nozzle bell under the body.
    revolve(nose, [(0.0, 0.0), (0.55 * r, 0.0), (0.72 * r, y0 + 0.03), (0.0, y0 + 0.03)], center=(bx, by, bz), segments=segments)
    # Chunky fins (tangential prisms) at 45 + 90k degrees so they never hide the porthole.
    for i in range(fin_count):
        a = 2 * math.pi * i / fin_count + math.pi / 4
        dx, dz = math.cos(a), math.sin(a)
        r0, r1 = 0.85 * r, 1.85 * r
        outline = [
            (bx + dx * r0, by + 0.02 * h, bz + dz * r0),
            (bx + dx * r1, by + 0.0, bz + dz * r1),
            (bx + dx * r1 * 0.95, by + 0.2 * h, bz + dz * r1 * 0.95),
            (bx + dx * r0, by + 0.42 * h, bz + dz * r0),
        ]
        prism(nose, outline, (-dz, 0, dx), max(0.14, 0.28 * r))
    # Porthole: glass disc + rim on the front (-Z) face.
    wy = by + 0.45 * h
    revolve(window, [(0.0, -0.05), (0.36 * r, -0.05), (0.36 * r, 0.07), (0.0, 0.07)], center=(bx, wy, bz - r * 0.99), segments=10, rot=rot_x(90))
    revolve(
        nose,
        [(0.34 * r, -0.07), (0.5 * r, -0.07), (0.5 * r, 0.09), (0.34 * r, 0.09)],
        center=(bx, wy, bz - r * 0.99),
        segments=10,
        closed=True,
        rot=rot_x(90),
    )
    return by + h


def _splat(piece, center, radius: float, seed: int, normal_axis: str = "z"):
    """Flat cartoon paint splat (deterministic wobbly outline) on a wall facing +-Z ("z") or +-X ("x")."""
    cx, cy, cz = center
    pts = []
    for k in range(12):
        a = 2 * math.pi * k / 12
        rr = radius * (1 + 0.24 * math.sin(3 * a + seed) + 0.12 * math.cos(5 * a + 2 * seed))
        if normal_axis == "z":
            pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a), cz))
        else:
            pts.append((cx, cy + rr * math.sin(a), cz + rr * math.cos(a)))
    prism(piece, pts, (0, 0, 1) if normal_axis == "z" else (1, 0, 0), 0.1)


def _hazard_band_stepped(yellow, black, center, size, stripe=0.9, step=0.04, angle=50.0):
    """
    Upright hazard band along X (like snkit.kit.hazard_band) whose BLACK stripes stop `step`
    below the yellow ones, so the two pieces never share a top plane. Same-height alternating
    stripe tops butt along a long run of short seams; Roblox simplifies each MeshPart's LOD on its
    own, and the audit (tests/zfight-audit.luau, LOD seam rule 5 in docs/areas-art.md) flags such
    a run as a curved same-height seam. A 0.04 step is invisible but removes the shared plane.

    size = (length, height, depth); center = band centre (Roblox space).
    Example: _hazard_band_stepped(yellow, black, (0, 0.4, -5.06), (16.0, 0.6, 0.14), stripe=0.8)
    """
    length, height, depth = size
    even, odd = _stripe_polys(length, height, stripe, angle)
    cx, cy, cz = center
    lowered = [(-length / 2, -height / 2), (length / 2, -height / 2), (length / 2, height / 2 - step), (-length / 2, height / 2 - step)]
    for poly in even:
        prism(yellow, [(cx + u, cy + v, cz) for u, v in poly], (0, 0, 1), depth)
    for poly in odd:
        clipped = clip_convex(poly, lowered)
        if clipped:
            prism(black, [(cx + u, cy + v, cz) for u, v in clipped], (0, 0, 1), depth)


def _figure_pieces(m: Model, shirt, pants, hat, accent=None, tool=None) -> dict:
    """Standard toy_figure piece set (StudsSmall body pieces + Smooth dark details)."""
    pieces = {
        "skin": m.piece("Skin", SKIN, material="StudsSmall"),
        "shirt": m.piece("Shirt", shirt, material="StudsSmall"),
        "pants": m.piece("Pants", pants, material="StudsSmall"),
        "dark": m.piece("Dark", CHARCOAL, material="Smooth"),
        "hat": m.piece("Hat", hat, material="StudsSmall"),
    }
    if accent is not None:
        pieces["accent"] = accent
    if tool is not None:
        pieces["tool"] = tool
    return pieces


# ------------------------------------------------------------------------------------------------
# Base: floor + entry arch
# ------------------------------------------------------------------------------------------------


def build_floor():
    """Concrete slab for the whole slot, darker machine zones, yellow walkway lines, hazard apron."""
    m = Model("A6_Floor", "slab centre at ground (place at slot (0, 0, 35)); top y = 0.4", budget=3000)
    slab = m.piece("Slab", FLOOR_GREY)
    zone = m.piece("Zone", ZONE_GREY)
    lines = m.piece("Lines", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    # Full slot width (x +-52): the neighbouring rows' floors butt this one edge to edge. At
    # SLOT_W - 0.4 a 0.2-stud strip of plot grass showed between the areas (World-QA, A1-art).
    block(slab, (0, FLOOR_TOP / 2, 0), (SLOT_W, FLOOR_TOP, SLOT_D - 0.4), bevel=0.15)
    top = FLOOR_TOP + 0.04
    # Darker machine zones (slot coords - (0, 35)): conveyor line, press/booth bay, dock apron.
    for x, z, sx, sz in ((26.0, 5.0, 38.0, 12.0), (-29.0, 13.0, 34.0, 32.0), (37.0, 22.0, 28.0, 14.0)):
        block(zone, (x, top, z), (sx, 0.1, sz), bevel=0.03)
    # Walkway edge lines from the road (z = -35) to the producer apron (z = 0).
    for s in (-1, 1):
        block(lines, (s * 6.4, top + 0.02, -18.9), (0.6, 0.12, 31.8), bevel=0.04)
    # Zebra crossing dashes at the road edge, inviting players in.
    for k in range(5):
        block(lines, (-4.4 + k * 2.2, top + 0.02, -32.6), (1.2, 0.12, 3.2), bevel=0.04)
    # Outline lines around the conveyor zone (x 9.2 .. 45). They start 0.2 past the hazard apron's
    # +X edge (x = 9): the apron's black stripes share the lines' top plane (y 0.53), so the two
    # must butt, never overlap (R18 rule 1).
    for z in (-1.0, 11.0):
        block(lines, (27.1, top + 0.03, z), (35.8, 0.12, 0.5), bevel=0.04)
    # Hazard apron in front of the producer (x in [-9, 9]).
    hazard_floor(lines, black, (0, top + 0.03, -1.6), (18.0, 2.2), 0.12, stripe=1.0)
    return m


ARCH_SIGN_Y = 20.2  # arch sign board centre: bottom edge 17.4 sits on the posts above the girder
ARCH_SIGN_Z = -0.2
LETTER_BLUE = DEEP_BLUE  # Smooth block letters on the white board (not Neon: R19)


def build_entry_arch():
    """
    Orange lattice pillars, blue girder with a hazard band, a DOUBLE-SIDED "ROCKET / FACTORY" sign
    (owner R17: block letters on both board faces, readable from the road and from inside the
    factory) and toy rockets standing on the girder ends.
    """
    m = Model("A6_EntryArch", "ground centre of the walkway opening; double-sided sign, front -Z (road)", budget=5500)
    truss_p = m.piece("Truss", ORANGE)
    base = m.piece("Base", DARK_STEEL)
    girder = m.piece("Girder", DEEP_BLUE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    board = m.piece("Board", WHITE, material="Smooth")
    letters = m.piece("Letters", LETTER_BLUE, material="Smooth")
    ornament = m.piece("Ornament", TOY_RED)
    window = m.piece("Window", SKY_BLUE, material="Smooth")
    for s in (-1, 1):
        x = s * 10.0
        block(base, (x, 0.4, 0), (4.4, 0.8, 4.4), bevel=0.15)
        hazard_band(yellow, black, (x, 0.4, -2.26), (4.0, 0.6, 0.14), stripe=0.6)
        truss(truss_p, (x, 0.8, 0), (x, 14.0, 0), 3.0, member=0.32, bays=5)
        block(girder, (x, 14.1, 0), (3.6, 0.4, 3.6), bevel=0.08)  # cap plate under the girder
    # Box girder lintel with a hazard band along its front face.
    block(girder, (0, 15.4, 0), (25.4, 2.4, 2.6), bevel=0.25)
    hazard_band(yellow, black, (0, 15.4, -1.36), (24.4, 1.4, 0.14), stripe=0.9)
    for x in (-12.0, -6.0, 0.0, 6.0, 12.0):
        block(base, (x, 15.4, -1.4), (0.5, 0.5, 0.14), bevel=0.04)  # bolt heads
    # Sign board above the girder on two short posts (post tops end inside the frame's bottom bar).
    # Letters: 0.28-stud cells, two lines of the 5x7 font = 4.48 tall on the 5.0-tall panel; each
    # copy sits on a panel face (half_gap = panel depth 0.49 / 2) and stands 0.22 proud of it, i.e.
    # 0.115 in front of the frame face, so letters, panel and frame never share a plane (R18).
    sign_frame(girder, board, (0, ARCH_SIGN_Y, ARCH_SIGN_Z), (18.0, 5.6), border=0.6, depth=0.7)
    sign_text(letters, ["ROCKET", "FACTORY"], (0, ARCH_SIGN_Y, ARCH_SIGN_Z), 0.28, 0.22, 0.245)
    for s in (-1, 1):
        bar(girder, (s * 6.0, 16.6, ARCH_SIGN_Z), (s * 6.0, ARCH_SIGN_Y - 2.6, ARCH_SIGN_Z), 0.5)
    # Toy rockets standing on the girder ends (white noses share the board piece: one draw call).
    for s in (-1, 1):
        toy_rocket(ornament, board, window, (s * 11.4, 16.6, 0), height=4.2, radius=0.75)
    return m


# ------------------------------------------------------------------------------------------------
# A6_FactoryShell: back wall, side walls, sawtooth roof frame + the producer
# ------------------------------------------------------------------------------------------------

# Back-wall column lines. The two end lines (+-50.8) are the factory CORNERS: the side walls own
# those columns (A6_ShellSide, z = +-23.6), so the back wall builds only the seven inner columns and
# its end bays run 0.05 into the side walls' corner columns (R18: one column per corner; a doubled
# column shared every face with its twin and z-fought along its whole height).
BACK_COLUMNS = (-50.8, -38.1, -25.4, -12.7, 0.0, 12.7, 25.4, 38.1, 50.8)
DOOR_X = (31.75, 44.45)  # roll-up doors in the two bays behind the loading dock
DOOR_TOP = 12.0
# Layout contract (AreaLayouts/Area06.luau SIDE_WALLS): side-wall centre lines at slot x = +-50.6.
SIDE_WALL_X = 50.6
CORNER_HALF = 1.2  # corner column half-width (A6_ShellSide `big` columns are 2.4 x 2.4)
CORNER_IN = SIDE_WALL_X - CORNER_HALF + 0.05  # back-wall bays end 0.05 inside the corner column
COPING_HALF = 1.3  # coping half-depth: 0.1 proud of every column (columns end inside it)
COLUMN_H = WALL_H + 0.3  # column tops sit inside the coping (coping y 22.0 .. 22.6)


def _wall_bay_along_x(panel, glass, trim, x0: float, x1: float):
    """
    One windowed wall bay between two columns (wall plane z in [-0.8, 0.8], along X). x0 / x1 are
    the column faces (or a point just inside a corner column).

    R18 (never flush): the glass runs 0.1 into the columns and its top ends inside the upper panel,
    the mullions run from the orange band up into the upper panel, and the sill (front z -1.0) is
    neither flush with the columns' front faces (z -1.2) nor with the glass ends.
    """
    xc, w = (x0 + x1) / 2, x1 - x0
    box(panel, (xc, 4.5, 0), (w, 9.0, 1.6))
    box(trim, (xc, 9.6, 0), (w, 1.2, 1.8))  # orange band
    box(glass, (xc, 14.15, 0), (w + 0.2, 7.9, 0.3))  # y 10.2 .. 18.1: top buried in the upper panel
    box(panel, (xc, 20.0, 0), (w, 4.0, 1.6))
    box(panel, (xc, 10.4, -0.1), (w, 0.4, 1.8))  # window sill, z -1.0 .. 0.8
    for k in (1, 2):
        box(panel, (x0 + w * k / 3, 14.1, 0), (0.35, 8.4, 0.6))  # mullions, y 9.9 .. 18.3


def build_shell_back():
    """
    Back wall along X between the side walls' corner columns (bays x in [-49.45, 49.45]), seven
    inner columns, window bays, two orange roll-up shutters and the coping (ends butt the side
    copings' inner faces at x = +-49.3).
    """
    m = Model("A6_ShellBack", "ground centre of the wall (place at slot (0, 0.4, 68.8)); inside faces -Z", budget=4500)
    panel = m.piece("Panel", PANEL)
    column = m.piece("Column", DEEP_BLUE)
    trim = m.piece("Trim", ORANGE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    shutter = m.piece("Shutter", ORANGE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    for x in BACK_COLUMNS[1:-1]:
        block(column, (x, COLUMN_H / 2, 0), (2.0, COLUMN_H, 2.4), bevel=0.2)
    last = len(BACK_COLUMNS) - 2
    for i in range(len(BACK_COLUMNS) - 1):
        x0 = -CORNER_IN if i == 0 else BACK_COLUMNS[i] + 1.0
        x1 = CORNER_IN if i == last else BACK_COLUMNS[i + 1] - 1.0
        xc, w = (x0 + x1) / 2, x1 - x0
        door = any(x0 < dx < x1 for dx in DOOR_X)
        if not door:
            _wall_bay_along_x(panel, glass, trim, x0, x1)
            continue
        # Shutter bay: slatted roll-up door (closed) under a hazard-striped lintel.
        box(panel, (xc, (DOOR_TOP + 1.2 + WALL_H) / 2, 0), (w, WALL_H - DOOR_TOP - 1.2, 1.6))
        # Lintel: orange lintel (y 12.0 .. 13.2) with a hazard band on its front, 0.1 shorter at the
        # top and black stripe tops stepped down again, so lintel, yellow and black tops are three
        # different planes (LOD seam rule 5: no long same-height seam between pieces).
        _hazard_band_stepped(yellow, black, (xc, DOOR_TOP + 0.55, -0.86), (w, 1.0, 0.14), stripe=0.9)
        box(trim, (xc, DOOR_TOP + 0.6, 0.1), (w, 1.2, 1.4))
        slats = 8
        for k in range(slats):
            y = DOOR_TOP * (k + 0.5) / slats
            block(shutter, (xc, y, 0.1), (w - 0.2, DOOR_TOP / slats, 1.0), bevel=0.18)
        block(column, (xc, 0.9, -0.55), (1.6, 0.4, 0.4), bevel=0.05)  # handle
    # Coping along the top, butting the side walls' copings (they cover the corners).
    block(trim, (0, WALL_H + 0.3, 0), (2 * (SIDE_WALL_X - COPING_HALF), 0.6, 2 * COPING_HALF), bevel=0.15)
    return m


SIDE_COLUMNS = (-23.6, -11.8, 0.0, 11.8, 23.6)


def build_shell_side():
    """
    Side wall along Z (z in [-24.8, 24.8]), symmetric in z so the same mesh serves both sides:
    +X edge with yaw 0 (inner face -X), -X edge with yaw 180 (inner face +X). Its end columns are
    the factory's CORNER columns (the back wall stops inside them). Columns end inside the coping;
    the coping is 0.1 proud of every column on all sides (R18 rule 2).
    """
    m = Model("A6_ShellSide", "ground centre of the wall; runs along Z, symmetric; inner face -X", budget=4500)
    panel = m.piece("Panel", PANEL)
    column = m.piece("Column", DEEP_BLUE)
    trim = m.piece("Trim", ORANGE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    for z in SIDE_COLUMNS:
        big = abs(z) > 23
        size = (2 * CORNER_HALF, COLUMN_H, 2 * CORNER_HALF) if big else (2.2, COLUMN_H, 2.0)
        block(column, (0, COLUMN_H / 2, z), size, bevel=0.2)
    for i in range(len(SIDE_COLUMNS) - 1):
        z0, z1 = SIDE_COLUMNS[i] + 1.0, SIDE_COLUMNS[i + 1] - 1.0
        zc, w = (z0 + z1) / 2, z1 - z0
        box(panel, (0, 3.5, zc), (1.6, 7.0, w))
        box(trim, (0, 7.6, zc), (1.8, 1.2, w))
        box(glass, (0, 12.65, zc), (0.3, 8.9, w + 0.2))  # y 8.2 .. 17.1, ends 0.1 into the columns
        box(panel, (0, 19.5, zc), (1.6, 5.0, w))
        box(panel, (-0.1, 8.4, zc), (1.8, 0.4, w))  # sill, x -1.0 .. 0.8 (columns are at -1.1 / -1.2)
        box(panel, (0, 12.6, zc), (0.6, 0.35, w + 0.1))  # transom, ends inside the columns
        box(panel, (0, 12.6, zc), (0.6, 9.4, 0.35))  # mullion, y 7.9 .. 17.3 (band up into the panel)
    # Coping: 0.1 proud of the corner columns' outer faces and ends (z +-24.9), so the back wall's
    # coping can butt its inner face (x -1.3) and the corner reads as one cap.
    block(trim, (0, WALL_H + 0.3, 0), (2 * COPING_HALF, 0.6, 2 * (SIDE_COLUMNS[-1] + CORNER_HALF + 0.1)), bevel=0.15)
    return m


# Sawtooth teeth: bottom chords at these local z, each tooth rises at its back chord (vertical glass).
ROOF_CHORDS = (-24.0, -9.0, 6.0, 21.0)
TOOTH_H = 6.0
RAFTER_X = (-50.0, -37.5, -25.0, -12.5, 0.0, 12.5, 25.0, 37.5, 50.0)


def build_roof_frame():
    """
    Open sawtooth roof frame spanning the factory (x in [-51, 51], z in [-24, 21] local): blue
    chords on the wall tops, orange sloped rafters (open bays: the camera sees straight in) and a
    glass clerestory on each tooth's vertical face.
    """
    m = Model("A6_RoofFrame", "ground centre of the factory (place at slot (0, 0.4, 46)); chords at y = 22.6", budget=4500)
    girder = m.piece("Girder", DEEP_BLUE)
    rafter = m.piece("Rafter", ORANGE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.5)
    span = 102.0
    for z in ROOF_CHORDS:
        block(girder, (0, ROOF_Y + 0.6, z), (span, 1.2, 1.2), bevel=0.12)
    for i in range(1, len(ROOF_CHORDS)):
        zv, zlo = ROOF_CHORDS[i], ROOF_CHORDS[i - 1]
        top = ROOF_Y + 1.2 + TOOTH_H
        # Ridge girder on top of the vertical face + glass clerestory under it. The glass runs 0.2
        # up into the ridge girder and 0.1 down into the chord; the mullion posts run 0.4 into the
        # ridge. Glass top (+0.2), post caps (+0.4) and the ridge underside (0) are three different
        # planes, so nothing coplanar overlaps (R18 rule 2).
        block(girder, (0, top + 0.5, zv), (span, 1.0, 1.0), bevel=0.1)
        box(glass, (0, ROOF_Y + 1.2 + TOOTH_H / 2 + 0.05, zv), (span - 1.0, TOOTH_H + 0.3, 0.2))
        for x in RAFTER_X:
            # Mullion post of the clerestory + one sloped rafter down to the previous chord.
            bar(girder, (x, ROOF_Y + 1.2, zv), (x, top + 0.4, zv), 0.5)
            bar(rafter, (x, top, zv - 0.4), (x, ROOF_Y + 1.2, zlo + 0.4), 0.7)
    return m


def build_rocket_line():
    """
    PRODUCER "Rocket Line": an orange lattice gantry with a yellow bridge over a big white toy
    rocket on its launch cradle, a blue parts hopper with a chute, and a control desk with a green
    status light (Bulb) and a big red button. Footprint ~17 x 10; bridge top y ~ 14.3.
    """
    m = Model("A6_RocketLine", "ground centre; front -Z; rocket on the cradle at local (0, 1.6, 0.5)", budget=4500)
    base = m.piece("Base", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    truss_p = m.piece("Truss", ORANGE)
    bridge = m.piece("Bridge", YELLOW)
    hopper = m.piece("Hopper", DEEP_BLUE)
    hull = m.piece("Hull", WHITE)
    nose = m.piece("Nose", TOY_RED)
    window = m.piece("Window", SKY_BLUE, material="Smooth")
    bulb = m.piece("Bulb", GLOW_GREEN, material="Neon")
    # Base plate + hazard band along the front edge (black stripe tops 0.04 lower: LOD seam rule).
    block(base, (0, 0.4, 0), (16.6, 0.8, 10.0), bevel=0.2)
    _hazard_band_stepped(yellow, black, (0, 0.4, -5.06), (16.0, 0.6, 0.14), stripe=0.8)
    # Cradle ring + four yellow clamps around the rocket foot.
    disc(base, (0, 0.8, 0.5), 2.8, 0.8, segments=20, bevel=0.15)
    hazard_ring(yellow, black, (0, 0, 0.5), 2.8, 3.3, 0.8, 1.0, count=16)
    for k in range(4):
        a = math.radians(90 * k)  # between the fins (fins sit at 45 + 90k)
        cx, cz = 2.35 * math.cos(a), 0.5 + 2.35 * math.sin(a)
        block(bridge, (cx, 2.4, cz), (0.8, 1.8, 0.8), bevel=0.12, rot=rot_y(-math.degrees(a)))
    # The big toy rocket (white hull, red nose + fins, blue porthole).
    toy_rocket(hull, nose, window, (0, 1.6, 0.5), height=10.0, radius=1.5, segments=16)
    # Gantry: two lattice towers + a yellow bridge with a hanging hook.
    for s in (-1, 1):
        truss(truss_p, (s * 5.4, 0.8, 0.5), (s * 5.4, 13.2, 0.5), 1.6, member=0.24, bays=5)
    block(bridge, (0, 13.7, 0.5), (12.6, 1.2, 2.2), bevel=0.2)
    _hazard_band_stepped(yellow, black, (0, 13.7, -0.66), (11.6, 0.8, 0.12), stripe=0.6)  # LOD seam rule
    bar(base, (2.0, 13.1, 0.5), (2.0, 12.0, 0.5), 0.12)
    block(base, (2.0, 11.8, 0.5), (0.7, 0.4, 0.7), bevel=0.08)
    # Parts hopper on legs at the front right with a chute toward the rocket.
    revolve(hopper, [(0.0, 3.0), (0.5, 3.0), (1.7, 5.2), (1.8, 6.0), (0.0, 6.0)], center=(6.9, 0.8, -2.8), segments=12)
    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(base, (6.9 + sx * 1.0, 0.8, -2.8 + sz * 1.0), (6.9 + sx * 0.9, 4.0, -2.8 + sz * 0.9), 0.3)
    bar(hopper, (6.2, 4.0, -2.2), (2.2, 3.2, -0.6), 0.7)
    for k in range(3):
        x = 6.4 + 0.5 * k
        prism(nose, [(x, 6.8, -3.0), (x + 0.9, 6.8, -3.0), (x, 8.0, -3.0)], (0, 0, 1), 0.2)  # spare fins
    # Control desk on the front left: blue desk, red button, green status light.
    block(hopper, (-6.6, 1.9, -3.2), (2.8, 2.2, 1.8), bevel=0.2)
    block(base, (-6.6, 3.1, -3.3), (3.0, 0.3, 2.0), bevel=0.06)
    disc(nose, (-7.2, 3.25, -3.4), 0.45, 0.35, segments=12, bevel=0.1)
    disc(bulb, (-6.0, 3.25, -3.4), 0.36, 0.3, segments=10, bevel=0.1)
    return m


# ------------------------------------------------------------------------------------------------
# Pads
# ------------------------------------------------------------------------------------------------

BELT_LEN = 34.0
BELT_TOP = 3.25


def build_conveyor():
    """
    Conveyor belt along local Z (z in [-17, 17]); the `Belt` slab's top face (y = 3.25) is the
    scrolling surface. Steel side rails, end drums, orange legs, hazard-striped skirts.
    """
    m = Model("A6_Conveyor", "ground centre; belt runs along local Z; belt top y = 3.25", budget=4500)
    belt = m.piece("Belt", CHARCOAL)
    frame = m.piece("Frame", DARK_STEEL)
    rollers = m.piece("Rollers", STEEL, material="StudsSmall")
    legs = m.piece("Legs", ORANGE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    box(belt, (0, BELT_TOP - 0.15, 0), (4.0, 0.3, BELT_LEN))
    for s in (-1, 1):
        cylinder(rollers, (-2.2, BELT_TOP - 0.45, s * BELT_LEN / 2), (2.2, BELT_TOP - 0.45, s * BELT_LEN / 2), 0.45, segments=12)
        block(frame, (s * 2.35, BELT_TOP - 0.2, 0), (0.5, 1.0, BELT_LEN + 0.8), bevel=0.1)
        block(frame, (s * 2.35, 1.95, 0), (0.24, 1.5, BELT_LEN), bevel=0.04)  # skirt backing
        hazard_band(yellow, black, (s * 2.52, 1.95, 0), (BELT_LEN - 0.4, 1.0, 0.12), stripe=1.4, axis="z")
    for z in (-15.0, -7.5, 0.0, 7.5, 15.0):
        for s in (-1, 1):
            block(legs, (s * 1.8, 1.4, z), (0.6, 2.8, 0.6), bevel=0.1)
            block(frame, (s * 1.8, 0.12, z), (1.1, 0.24, 1.1), bevel=0.05)
        block(legs, (0, 1.0, z), (3.2, 0.4, 0.4), bevel=0.06)
    # Drive motor at the -Z end.
    block(legs, (2.9, 2.6, -15.5), (1.4, 1.4, 1.8), bevel=0.2)
    # Drive shaft from inside the side rail (x 2.1 .. 2.6) into the motor: its end cap is buried, not
    # flush with the motor's -X face (R18).
    cylinder(rollers, (2.35, 2.8, -16.2), (2.9, 2.8, -16.2), 0.3, segments=8)
    return m


def build_toy_rocket():
    """Small candy toy rocket (~3.2 tall) riding the belt; `Rocket` body is tinted per spawn."""
    m = Model("A6_ToyRocket", "centre under the fins; nose up; porthole faces -Z", budget=1500)
    hull = m.piece("Rocket", MINT, material="StudsSmall", tinted=True)
    nose = m.piece("Nose", WHITE, material="StudsSmall")
    window = m.piece("Window", SKY_BLUE, material="Smooth")
    toy_rocket(hull, nose, window, (0, 0, 0), height=3.2, radius=0.55)
    return m


ARM_HINGE = 8.4  # robot-arm hinge height (local); Arm bbox centre == (0, ARM_HINGE, 0)
ARM_REACH = 4.4  # gripper / counterweight distance from the hinge along Z


def build_robot_arm():
    """
    Factory robot: static pedestal + turret + yoke, and a nodding `Arm` that is point-symmetric
    about its hinge (0, 8.4, 0): boom through the hinge, gripper hanging down at the front (-Z)
    end, a counterweight of identical extent standing up at the back. The FX controller
    oscillates the Arm +-22 deg about local X through its bbox centre == the hinge.
    """
    m = Model("A6_RobotArm", "ground centre; gripper reaches local (0, ~5.6, -4.4); hinge (0, 8.4, 0)", budget=2500)
    base = m.piece("Base", DARK_STEEL)
    body = m.piece("Body", ORANGE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    arm = m.piece("Arm", YELLOW)
    h = ARM_HINGE
    disc(base, (0, 0, 0), 1.8, 0.5, segments=16, bevel=0.12)
    hazard_ring(yellow, black, (0, 0, 0), 1.2, 1.8, 0.5, 0.62, count=12)
    cylinder(body, (0, 0.5, 0), (0, 6.6, 0), 0.9, segments=12)
    block(body, (0, 7.1, 0), (2.4, 1.0, 2.4), bevel=0.25)
    for s in (-1, 1):
        block(base, (s * 1.05, 8.1, 0), (0.4, 2.2, 1.5), bevel=0.08)  # yoke plates
    cylinder(base, (-1.3, h, 0), (1.3, h, 0), 0.32, segments=8)  # static axle pin
    # Arm — every primitive below is mirrored through the hinge so the bbox centre is the hinge.
    cylinder(arm, (-0.75, h, 0), (0.75, h, 0), 0.7, segments=12)  # hub
    block(arm, (0, h, 0), (1.0, 0.9, 2 * ARM_REACH + 0.9), bevel=0.15)  # boom through the hinge
    low = h - 2.8  # lowest point of the gripper fingers
    # Front: forearm, wrist plate, two claw fingers.
    block(arm, (0, h - 0.8, -ARM_REACH), (0.9, 1.6, 0.9), bevel=0.12)
    block(arm, (0, h - 1.8, -ARM_REACH), (1.4, 0.4, 1.4), bevel=0.08)
    for s in (-1, 1):
        bar(arm, (s * 0.5, h - 2.0, -ARM_REACH), (s * 0.45, low + 0.2, -ARM_REACH - 0.3 * s), 0.25)
        # Claw pad: its flat bottom is exactly `low`, so the bbox stays centred on the hinge.
        block(arm, (s * 0.45, low + 0.1, -ARM_REACH - 0.3 * s), (0.36, 0.2, 0.36), bevel=0.04)
    # Back: counterweight filling the mirrored extent (x +-0.7, y h..2h-low, z REACH +- 0.7).
    top = 2 * h - low
    block(arm, (0, (h + top) / 2, ARM_REACH), (1.4, top - h, 1.4), bevel=0.2)
    return m


def build_fin_press():
    """
    Fin press: blue frame, steel hydraulic cylinder and ram over a die with a red fin blank, a
    hazard-striped bed, a bin of finished fins and a side flywheel (`Wheel`, spins about local X,
    symmetric about the X axis through its bbox centre (4.6, 7.0, 0)).
    """
    m = Model("A6_FinPress", "ground centre; front -Z; flywheel on the +X side", budget=3000)
    bed = m.piece("Bed", DARK_STEEL)
    frame = m.piece("Frame", DEEP_BLUE)
    steel = m.piece("Steel", STEEL, material="StudsSmall")
    wheel = m.piece("Wheel", ORANGE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    fins = m.piece("Fins", TOY_RED)
    bin_p = m.piece("Bin", YELLOW)
    block(bed, (0, 1.2, 0), (6.0, 2.4, 4.4), bevel=0.2)
    hazard_band(yellow, black, (0, 1.2, -2.26), (5.6, 1.0, 0.14), stripe=0.6)
    block(steel, (0, 2.65, 0), (3.6, 0.5, 2.6), bevel=0.1)
    prism(fins, [(-1.2, 3.0, 0.9), (1.4, 3.0, 0.9), (-1.2, 3.0, -0.9)], (0, 1, 0), 0.25)  # fin blank
    for s in (-1, 1):
        block(frame, (s * 3.4, 4.5, 0), (1.2, 9.0, 1.8), bevel=0.2)
    block(frame, (0, 9.9, 0), (8.0, 1.8, 2.4), bevel=0.25)
    cylinder(steel, (0, 9.0, 0), (0, 6.8, 0), 0.8, segments=12)
    for s in (-1, 1):
        cylinder(steel, (s * 1.5, 9.0, 0), (s * 1.5, 5.6, 0), 0.18, segments=8)  # guide rods
    block(bed, (0, 6.2, 0), (3.8, 1.2, 2.8), bevel=0.15)  # ram head
    # Flywheel on the +X side, axle into the column.
    cylinder(steel, (3.9, 7.0, 0), (4.3, 7.0, 0), 0.3, segments=8)
    revolve(wheel, [(1.85, -0.2), (2.2, -0.2), (2.2, 0.2), (1.85, 0.2)], center=(4.6, 7.0, 0), segments=16, closed=True, rot=rot_z(90))
    cylinder(wheel, (4.3, 7.0, 0), (4.9, 7.0, 0), 0.5, segments=10)
    for k in range(4):
        a = math.radians(90 * k)
        bar(wheel, (4.6, 7.0 + 0.4 * math.cos(a), 0.4 * math.sin(a)), (4.6, 7.0 + 1.9 * math.cos(a), 1.9 * math.sin(a)), 0.3)
    # Bin of finished fins on the front left.
    block(bin_p, (-5.4, 0.8, -1.2), (1.9, 1.6, 2.2), bevel=0.2)
    for k in range(3):
        x = -5.9 + 0.5 * k
        prism(fins, [(x, 1.4, -1.6), (x, 1.4, -0.4), (x, 2.6, -1.4)], (1, 0, 0), 0.2)
    return m


def build_paint_booth():
    """
    Open-front paint booth: off-white shell with blue trim, a purple toy rocket on a turntable,
    two steel spray nozzles, splats in three candy colours, and a vent `Fan` (spins about local Z)
    centred on the front fascia at (0, 8.9, -5.1).
    """
    m = Model("A6_PaintBooth", "ground centre; open side faces -Z; Fan centre (0, 8.9, -5.1)", budget=4500)
    floor = m.piece("Floor", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    booth = m.piece("Booth", OFF_WHITE)
    trim = m.piece("Trim", DEEP_BLUE)
    fan = m.piece("Fan", CHARCOAL)
    nozzles = m.piece("Nozzles", STEEL, material="StudsSmall")
    hull = m.piece("Hull", PURPLE, material="StudsSmall")
    nose = m.piece("Nose", WHITE, material="StudsSmall")
    pink = m.piece("SplatPink", PINK)
    blue = m.piece("SplatBlue", SKY_BLUE)
    lime = m.piece("SplatLime", LIME)
    block(floor, (0, 0.2, 0), (10.4, 0.4, 10.4), bevel=0.1)
    # Kick band on the floor plate's front edge, 0.05 proud of it (z -5.25 .. -4.85): its front face
    # never shares the plate's front plane (R18 rule 2).
    hazard_band(yellow, black, (0, 0.25, -5.05), (9.6, 0.5, 0.4), stripe=0.6)
    block(booth, (0, 5.2, 4.7), (10.0, 9.6, 0.6), bevel=0.12)
    for s in (-1, 1):
        block(booth, (s * 4.7, 5.2, 0), (0.6, 9.6, 10.0), bevel=0.12)
    block(booth, (0, 10.3, 0), (10.6, 0.6, 10.6), bevel=0.15)
    block(booth, (0, 8.9, -4.7), (8.8, 2.2, 0.6), bevel=0.1)  # front fascia over the opening
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(trim, (sx * 5.0, 5.3, sz * 5.0), (0.8, 10.4, 0.8), bevel=0.12)
    block(trim, (0, 10.75, -5.1), (10.8, 0.5, 0.6), bevel=0.08)
    # Vent fan on the fascia: housing ring (trim) + 4-blade fan (symmetric about local Z).
    revolve(trim, [(0.9, -0.15), (1.15, -0.15), (1.15, 0.2), (0.9, 0.2)], center=(0, 8.9, -5.05), segments=16, closed=True, rot=rot_x(90))
    cylinder(fan, (0, 8.9, -4.95), (0, 8.9, -5.25), 0.25, segments=8)
    for k in range(2):  # two crossing bars = four blades, point-symmetric about the hub
        box(fan, (0, 8.9, -5.1), (1.7, 0.36, 0.08), rot=rot_z(45 + 90 * k) @ rot_x(12))
    # Turntable + the rocket being painted.
    disc(floor, (0, 0.4, 0.6), 2.1, 0.4, segments=20, bevel=0.1)
    toy_rocket(hull, nose, blue, (0, 0.8, 0.6), height=6.4, radius=0.95, segments=14)
    # Spray nozzles hanging from the ceiling, aimed at the rocket.
    for s in (-1, 1):
        bar(nozzles, (s * 3.0, 10.0, 0.6), (s * 3.0, 6.0, 0.6), 0.3)
        bar(nozzles, (s * 3.0, 6.0, 0.6), (s * 2.0, 5.2, 0.6), 0.3)
        cylinder(nozzles, (s * 2.0, 5.2, 0.6), (s * 1.6, 4.9, 0.6), 0.3, segments=8, radius_b=0.14)
    # Splats: inside back wall + outside of both side walls (+ paint cans in matching colours).
    _splat(pink, (-2.6, 6.8, 4.36), 1.1, 1, "z")
    _splat(lime, (2.8, 3.2, 4.36), 0.9, 2, "z")
    _splat(blue, (5.06, 6.0, -1.6), 1.2, 3, "x")
    _splat(pink, (5.06, 2.6, 2.4), 0.8, 4, "x")
    _splat(lime, (-5.06, 5.0, 1.0), 1.1, 5, "x")
    _splat(blue, (-5.06, 2.2, -2.8), 0.7, 6, "x")
    for i, piece in enumerate((pink, lime, blue)):
        x = -3.4 + 1.2 * i
        cylinder(piece, (x, 0.4, 3.6), (x, 1.5, 3.6), 0.45, segments=10)
    return m


def build_quality_check():
    """
    Scanner arch over the conveyor: blue posts at z = +-3.7 (the belt passes along local X), a
    white housing, a cyan scan bar (`Glow`: bobs +-0.3, lights) between the posts and a big green
    check mark (`Bulb`: static + light) on a blue badge facing -Z.
    """
    m = Model("A6_QualityCheck", "ground centre; tunnel along local X (belt passes through); badge faces -Z", budget=3000)
    post = m.piece("Post", DEEP_BLUE)
    housing = m.piece("Housing", WHITE)
    base = m.piece("Base", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    glow = m.piece("Glow", SCAN_CYAN, material="Neon")
    bulb = m.piece("Bulb", GLOW_GREEN, material="Neon")
    for s in (-1, 1):
        z = s * 3.7
        block(base, (0, 0.3, z), (2.4, 0.6, 2.0), bevel=0.1)
        block(post, (0, 4.6, z), (1.6, 8.2, 1.2), bevel=0.2)
        hazard_band(yellow, black, (0, 1.4, z - 0.66), (1.4, 1.0, 0.12), stripe=0.5)
        block(base, (0, 5.4, z - s * 0.75), (0.9, 3.0, 0.3), bevel=0.06)  # scanner emitter strip
    block(housing, (0, 9.6, 0), (2.8, 2.0, 9.4), bevel=0.3)
    # Scan bar: free between the posts' emitters so the +-0.3 bob never clips.
    box(glow, (0, 5.4, 0), (0.45, 0.3, 5.6))
    # Badge + check mark on top, facing the road.
    revolve(post, [(0.0, -0.2), (2.0, -0.2), (2.0, 0.2), (0.0, 0.2)], center=(0, 12.8, -0.2), segments=18, rot=rot_x(90))
    block(post, (0, 10.9, -0.2), (0.8, 0.6, 0.6), bevel=0.1)
    prism(bulb, [(-1.25, 12.9, -0.45), (-0.85, 13.3, -0.45), (-0.25, 12.7, -0.45), (-0.65, 12.3, -0.45)], (0, 0, 1), 0.2)
    prism(bulb, [(-0.65, 12.3, -0.45), (-0.25, 12.7, -0.45), (1.15, 14.0, -0.45), (1.45, 13.6, -0.45)], (0, 0, 1), 0.2)
    return m


def build_forklift():
    """Chunky yellow toy forklift carrying a pallet of orange crates on its forks (front = -Z).

    R56 drivable split: per-axle TyresF (z -1.7) / TyresR (z 1.7), r 0.85 at x +-1.9, each with a
    spoked HubsF / HubsR cap (bbox centre = axle point, see models/area03.axle_wheels). The load
    stays `Pallet` + `Crates` (unchanged names / positions)."""
    m = Model(
        "A6_Forklift",
        "ground centre; forks + pallet toward -Z; beacon on the cage roof; axles z -1.7 / 1.7, wheel r 0.85",
        budget=3000,
    )
    body = m.piece("Body", YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    seat = m.piece("Seat", CHARCOAL)
    cage = m.piece("Cage", DARK_STEEL)
    forks = m.piece("Forks", STEEL, material="StudsSmall")
    pallet = m.piece("Pallet", WOOD)
    crates = m.piece("Crates", ORANGE)
    neon = m.piece("Neon", ORANGE, material="Neon")
    for suffix, z in (("F", -1.7), ("R", 1.7)):
        tyres = m.piece("Tyres" + suffix, TYRE, material="Smooth")
        hubs = m.piece("Hubs" + suffix, STEEL, material="StudsSmall")
        axle_wheels(tyres, hubs, 1.9, z, 0.85, 0.7)
    block(body, (0, 1.6, 0.2), (3.4, 1.6, 5.4), bevel=0.3)
    block(body, (0, 2.6, 2.4), (3.4, 2.0, 1.4), bevel=0.35)  # counterweight
    hazard_band(body, black, (0, 2.6, 3.16), (3.0, 1.2, 0.14), stripe=0.5)
    block(seat, (0, 2.9, 0.9), (1.6, 0.6, 1.4), bevel=0.15)
    block(seat, (0, 3.8, 1.5), (1.6, 1.6, 0.4), bevel=0.12)
    bar(seat, (0, 2.4, -0.9), (0, 3.6, -0.4), 0.22)
    disc(seat, (0, 3.6, -0.45), 0.55, 0.16, segments=12, bevel=0.05)  # steering ring
    for sx in (-1, 1):
        for z in (-1.1, 2.0):
            bar(cage, (sx * 1.5, 2.4, z), (sx * 1.5, 6.0, z), 0.24)
    block(cage, (0, 6.1, 0.45), (3.4, 0.3, 3.6), bevel=0.08)
    # Mast + carriage + forks.
    for sx in (-1, 1):
        block(cage, (sx * 1.1, 3.6, -2.9), (0.4, 6.4, 0.5), bevel=0.06)
    for y in (2.0, 4.6, 6.6):
        block(cage, (0, y, -2.9), (2.6, 0.3, 0.4), bevel=0.05)
    for sx in (-1, 1):
        block(forks, (sx * 0.8, 1.15, -4.7), (0.4, 0.2, 3.4), bevel=0.04)
        block(forks, (sx * 0.8, 1.6, -3.15), (0.4, 1.0, 0.25), bevel=0.04)
    # Pallet + two crates with banding.
    block(pallet, (0, 1.5, -4.75), (3.4, 0.5, 3.2), bevel=0.08)
    block(crates, (0, 2.6, -4.2), (2.8, 1.7, 1.6), bevel=0.2)
    block(crates, (0.2, 2.4, -5.6), (2.2, 1.3, 1.2), bevel=0.2)
    block(pallet, (0, 2.6, -4.2), (2.9, 0.25, 1.65), bevel=0.04)
    # Beacon on the roof.
    disc(cage, (0, 6.25, 0.6), 0.32, 0.15, segments=10, bevel=0.04)
    revolve(neon, [(0.0, 0.0), (0.26, 0.0), (0.26, 0.3), (0.0, 0.45)], center=(0, 6.4, 0.6), segments=10)
    return m


# ------------------------------------------------------------------------------------------------
# A6_DeliveryTruck (owner R56 "trucks drive in and out"; the owner calls it the "semi-truck")
# ------------------------------------------------------------------------------------------------

TRUCK_HALF_L = 7.25  # total length 14.5 (front bumper z -7.25 .. rear bumper z +7.25)
TRUCK_WHEEL_R = 1.0  # every axle: wheel radius 1.0, axle at y 1.0
TRUCK_WHEEL_X = 1.9  # tyre mid-plane |x| (tyre 0.8 wide -> x 1.5 .. 2.3, hub caps to 2.44)
TRUCK_AXLES = (("F", -5.4), ("M", 3.4), ("R", 5.6))  # front axle under the cab + rear tandem
TRUCK_DECK_TOP = 2.3  # flatbed deck top (deck slab y 2.04 .. 2.3, just above the tyre tops at 2.0)
TRUCK_CARGO = (  # (piece, centre z, size): 4 toy crates in a row on the deck, sunk 0.02 into it
    ("Cargo1", -1.45, (3.2, 2.0, 1.9)),
    ("Cargo2", 0.95, (3.0, 1.8, 1.9)),
    ("Cargo3", 3.4, (3.2, 2.0, 1.9)),
    ("Cargo4", 5.85, (3.0, 1.8, 1.9)),
)


def _rocket_crate(piece, center, size):
    """
    Orange toy crate (ONE `CargoN` piece, single colour): rounded block with a raised toy-rocket
    emblem (body + nose + two fins, convex parts) on both side (+-X) faces, 0.08 proud, so it reads
    through shading from a passing camera. Every vertex stays inside this crate's own piece.

    center: crate centre; size: (x, y, z). Example: _rocket_crate(m.piece("Cargo1", ORANGE), (0, 3.28, -1.45), (3.2, 2.0, 1.9))
    """
    cx, cy0, cz = center
    block(piece, center, size, bevel=0.16)
    cy = cy0 + 0.12  # emblem sits a little high so the stake rail (top y ~3.05) never hides its fins
    for sx in (-1, 1):
        xf = cx + sx * (size[0] / 2 + 0.05)  # emblem mid-plane: 0.02 inside the face, 0.12 proud
        box(piece, (xf, cy - 0.06, cz), (0.14, 0.62, 0.36))  # rocket body
        prism(piece, [(xf, cy + 0.25, cz - 0.2), (xf, cy + 0.25, cz + 0.2), (xf, cy + 0.62, cz)], (1, 0, 0), 0.14)  # nose
        for sz in (-1, 1):  # fins flaring out at the base
            prism(
                piece,
                [(xf, cy - 0.37, cz + sz * 0.17), (xf, cy + 0.0, cz + sz * 0.17), (xf, cy - 0.47, cz + sz * 0.45)],
                (1, 0, 0),
                0.14,
            )


def build_delivery_truck():
    """
    Cartoon cab-over semi-truck with a flatbed of orange toy crates (owner R56: the truck drives in,
    backs up to A6_LoadingDock, gets loaded crate by crate and drives off). Red cab with a blue
    stripe, big windshield, roof air deflector and twin exhaust stacks; white flatbed with blue edge
    fascia, low yellow stake rails and a headache rack behind the cab.

    Size (hard limits from V1-vehicles): length 14.5 (z -7.25 .. 7.25), width <= 5.0 incl. mirrors
    (mirror heads reach |x| 2.48), height <= 7.2 (deflector top 6.85).

    Drivable pieces (contract in models/area03.py "Drivable vehicle kit"):
        TyresF / TyresM / TyresR  one piece per axle (z -5.4 / 3.4 / 5.6), wheel r 1.0, bbox centre
        HubsF  / HubsM  / HubsR   = axle point (0, 1.0, z); spoked steel caps on the outer faces
        BrakeLights               two rear lamps on the light panel (Smooth; client -> Neon)
        IndicatorL / IndicatorR   amber front (apron) + rear (light panel) corner lamps, -X / +X
        Cargo1 .. Cargo4          one crate each, front to back, modelled loaded on the deck
    Static: Cab, Stripe, Glass, Headlights (small Neon discs, R19), Chassis, Deck, Rails.
    """
    m = Model(
        "A6_DeliveryTruck",
        "ground centre; cab (front) toward -Z; z -7.25 .. 7.25, |x| <= 2.5, top y 6.85; "
        "axles z -5.4 / 3.4 / 5.6, wheel r 1.0; deck top y 2.3",
        budget=4500,
    )
    cab = m.piece("Cab", TOY_RED)
    stripe = m.piece("Stripe", DEEP_BLUE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.35)
    lights = m.piece("Headlights", LAMP_WARM, material="Neon")
    brake = m.piece("BrakeLights", TOY_RED, material="Smooth")
    ind_l = m.piece("IndicatorL", AMBER, material="Smooth")
    ind_r = m.piece("IndicatorR", AMBER, material="Smooth")
    chassis = m.piece("Chassis", DARK_STEEL)
    deck = m.piece("Deck", WHITE)
    rails = m.piece("Rails", YELLOW)

    # --- Wheels: one Tyres + one Hubs piece per axle (bbox centre = axle point).
    for suffix, z in TRUCK_AXLES:
        tyres = m.piece("Tyres" + suffix, TYRE)
        hubs = m.piece("Hubs" + suffix, STEEL, material="StudsSmall")
        axle_wheels(tyres, hubs, TRUCK_WHEEL_X, z, TRUCK_WHEEL_R, 0.8)
        cylinder(chassis, (-1.55, TRUCK_WHEEL_R, z), (1.55, TRUCK_WHEEL_R, z), 0.17, segments=8)  # axle

    # --- Cab-over cab: body sits above the front wheels (bottom y 2.15, tyre tops at 2.0).
    block(cab, (0, 3.95, -5.1), (4.4, 3.6, 3.5), bevel=0.4, segments=2)  # x +-2.2, z -6.85 .. -3.35
    # Roof air deflector: wedge rising toward the back of the cab (top y 6.85).
    prism(cab, [(0, 5.55, -5.5), (0, 5.55, -3.45), (0, 6.85, -3.45), (0, 6.85, -3.95)], (1, 0, 0), 3.8)
    # Lower front apron in front of the front wheels (gap 0.05 to the tyre).
    block(cab, (0, 1.75, -6.7), (4.2, 1.3, 0.5), bevel=0.12)
    # Windshield + door windows (Glass), headlight eyes (small Neon discs), grille with slats.
    box(glass, (0, 4.625, -6.88), (3.4, 1.35, 0.1))
    for sx in (-1, 1):
        box(glass, (sx * 2.22, 4.6, -5.6), (0.1, 1.2, 1.6))
        revolve(lights, [(0.0, -0.07), (0.3, -0.07), (0.3, 0.07), (0.0, 0.07)], center=(sx * 1.4, 3.2, -6.9), segments=12, rot=rot_x(90))
    block(chassis, (0, 3.08, -6.88), (1.7, 0.9, 0.12), bevel=0.05)
    for y in (2.83, 3.08, 3.33):
        box(chassis, (0, y, -6.95), (1.5, 0.1, 0.06))
    # Blue stripe: a bold band + a pin line down both cab sides, the pin line across the front.
    for sx in (-1, 1):
        block(stripe, (sx * 2.23, 3.15, -5.1), (0.1, 0.42, 2.6), bevel=0.03)
        box(stripe, (sx * 2.23, 3.72, -5.1), (0.1, 0.16, 2.6))
    box(stripe, (0, 3.72, -6.88), (3.5, 0.16, 0.1))
    # Front bumper + side mirrors (arm + head; heads end at |x| 2.48).
    block(chassis, (0, 0.95, -7.0), (4.5, 0.6, 0.5), bevel=0.15)
    for sx in (-1, 1):
        bar(chassis, (sx * 2.15, 4.4, -6.55), (sx * 2.42, 4.4, -6.55), 0.1)
        block(chassis, (sx * 2.42, 4.75, -6.55), (0.12, 0.8, 0.4), bevel=0.03)

    # --- Chassis: frame rails, cab mount, deck cross-members, fuel tanks, step boxes, stacks.
    for sx in (-1, 1):
        block(chassis, (sx * 0.85, 1.425, 0.0), (0.4, 0.55, 13.4), bevel=0.06)
        cylinder(chassis, (sx * 1.62, 1.35, -2.55), (sx * 1.62, 1.35, -0.75), 0.48, segments=12)  # fuel tank
        block(chassis, (sx * 1.85, 1.525, -3.9), (0.7, 1.35, 0.7), bevel=0.08)  # step box under the door
        block(chassis, (sx * 2.0, 1.05, -3.9), (0.5, 0.16, 0.76), bevel=0.04)  # tread sticking out
        cylinder(chassis, (sx * 1.75, 1.95, -3.13), (sx * 1.75, 6.6, -3.13), 0.15, segments=10)  # exhaust stack
    block(chassis, (0, 1.95, -5.1), (2.0, 0.5, 2.8), bevel=0.06)  # cab mount
    box(chassis, (0, 1.875, -3.13), (4.0, 0.45, 0.36))  # catwalk between cab and deck (stacks stand on it)
    for sx in (-1, 1):
        box(chassis, (sx * 1.2, 1.35, -1.65), (0.4, 0.3, 0.3))  # fuel-tank bracket (frame rail -> tank)
    for z in (-2.4, 0.2, 2.0, 4.5, 6.45):
        box(chassis, (0, 1.87, z), (2.6, 0.36, 0.3))  # deck cross-member (rails top 1.7 -> deck bottom 2.04)

    # --- Flatbed deck (white) + blue edge fascia.
    block(deck, (0, TRUCK_DECK_TOP - 0.13, 2.025), (4.5, 0.26, 9.85), bevel=0.06)  # z -2.9 .. 6.95
    for sx in (-1, 1):
        box(stripe, (sx * 2.28, TRUCK_DECK_TOP - 0.13, 2.025), (0.08, 0.2, 9.75))

    # --- Low stake rails (yellow) + headache rack behind the cab.
    top = TRUCK_DECK_TOP
    for sx in (-1, 1):
        x = sx * 2.1
        for z in (-0.25, 2.18, 4.62, 6.72):
            bar(rails, (x, top - 0.05, z), (x, top + 0.75, z), 0.2)
        bar(rails, (x, top + 0.65, -2.75), (x, top + 0.65, 6.8), 0.16)
    for sx in (-1, 0, 1):
        bar(rails, (sx * 2.1, top - 0.05, -2.75), (sx * 2.1, top + 2.2, -2.75), 0.22)
    for y in (top + 0.65 + 0.06, top + 1.45, top + 2.2):
        bar(rails, (-2.1, y, -2.75), (2.1, y, -2.75), 0.18)

    # --- Rear: light panel + bumper, brake lights and rear indicators on the panel.
    block(chassis, (0, 1.7, 6.85), (4.4, 0.7, 0.3), bevel=0.06)  # z 6.7 .. 7.0
    block(chassis, (0, 1.12, 7.08), (4.2, 0.5, 0.34), bevel=0.12)  # bumper, back face z 7.25
    for sx in (-1, 1):
        block(brake, (sx * 1.2, 1.7, 7.03), (0.9, 0.42, 0.1), bevel=0.03)
        ind = ind_r if sx > 0 else ind_l
        block(ind, (sx * 1.95, 1.7, 7.03), (0.38, 0.42, 0.1), bevel=0.03)  # rear corner
        block(ind, (sx * 1.6, 1.8, -6.98), (0.6, 0.32, 0.1), bevel=0.03)  # front corner (apron)

    # --- Cargo: four orange toy crates, front to back (the client pops them in one by one).
    for name, z, size in TRUCK_CARGO:
        _rocket_crate(m.piece(name, ORANGE), (0, top - 0.02 + size[1] / 2, z), size)
    return m


def build_loading_dock():
    """
    Raised loading dock (24 x 8, top y = 1.6) with a hazard-striped edge, rubber bumpers, steps,
    pallets of crates and a pallet of pink toy rockets.

    R56: the dock no longer carries a parked truck. The drivable `A6_DeliveryTruck` (its own
    model, see build_delivery_truck) backs up to the bumpers and drives away; its old resting spot
    was dock-local (6, 0, -10), cab toward the road (-Z). Pieces: Dock, Edge, HazardYellow,
    HazardBlack, Bumpers (the two rubber dock bumpers), Pallet, Crates, Toys (pink rocket hulls),
    Box (white rocket noses / fins), Stripe (rocket portholes).
    """
    m = Model("A6_LoadingDock", "ground centre of the dock; dock edge (bumpers) at local z = -4; trucks pull up in front (-Z)", budget=4500)
    dock = m.piece("Dock", CONCRETE_DARK)
    edge = m.piece("Edge", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    bumpers = m.piece("Bumpers", TYRE, material="Smooth")
    pallet = m.piece("Pallet", WOOD)
    crates = m.piece("Crates", ORANGE)
    toys = m.piece("Toys", PINK, material="StudsSmall")
    white = m.piece("Box", WHITE)
    stripe = m.piece("Stripe", DEEP_BLUE)
    # Dock body + steel nosing + hazard band + bumpers + steps on the -X end.
    block(dock, (0, 0.8, 0), (24.0, 1.6, 8.0), bevel=0.2)
    block(edge, (0, 1.55, -3.85), (24.0, 0.2, 0.5), bevel=0.04)
    hazard_band(yellow, black, (0, 0.8, -4.06), (23.4, 0.9, 0.14), stripe=1.0)
    for x in (3.4, 8.6):
        block(bumpers, (x, 0.9, -4.3), (1.0, 1.2, 0.6), bevel=0.12)
    for k in range(3):
        step_h = 0.4 * (3 - k)
        block(dock, (-12.4 - 0.8 * k, step_h / 2, -1.0), (0.8, step_h, 4.0), bevel=0.08)
    # Pallets on the dock: crates, and a pallet of upright pink toy rockets.
    for x, kind in ((-8.0, "crates"), (-2.6, "rockets"), (2.6, "crates")):
        block(pallet, (x, 1.85, 0.8), (3.4, 0.5, 3.4), bevel=0.08)
        if kind == "crates":
            block(crates, (x - 0.4, 2.95, 0.5), (2.2, 1.7, 2.2), bevel=0.2)
            block(crates, (x + 0.6, 4.35, 0.9), (1.6, 1.1, 1.6), bevel=0.18)
        else:
            for dx, dz in ((-0.8, -0.2), (0.8, -0.2), (0.0, 1.2)):
                toy_rocket(toys, white, stripe, (x + dx, 2.1, 0.8 + dz), height=2.6, radius=0.42, segments=10)
    return m


def build_factory_boss():
    """
    Mezzanine office (deck y = 5.6, stairs down to +X) with a BOSS sign and the boss + megaphone.

    Animated NPC (owner R30): the boss is split into rig pieces (Torso*/Head*/ArmL*/ArmR*/LegL*/
    LegR*, see models/_npc_rig.py) so the client ManagerController can pace him along the deck,
    swing his limbs, wave (raises the relaxed left arm) and jab the megaphone. The office (frame,
    deck, railings, stairs, desk, sign) stays a static prop. His megaphone is its own yellow piece
    (riding the right arm) so the railing's HazardYellow can never be pulled into the rig.
    """
    from models._npc_rig import a4_bones, rig_split

    m = Model("A6_FactoryBoss", "ground centre of the deck; boss + sign face -Z; stairs toward +X", budget=4500)
    frame = m.piece("Frame", DEEP_BLUE)
    deck = m.piece("Deck", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    sign = m.piece("Sign", WHITE, material="Smooth")
    tie = m.piece("Tie", TOY_RED, material="StudsSmall")
    megaphone = m.piece("Megaphone", HAZARD_YELLOW, material="StudsSmall")
    pieces = _figure_pieces(m, SKY_BLUE, DEEP_BLUE, WHITE, accent=tie, tool=megaphone)
    for sx in (-1, 1):
        # Post faces (z +-0.4) sit INSIDE the deck's z -3.0..4.0, never flush with its ends (R18).
        for z in (-2.5, 3.5):
            block(frame, (sx * 4.0, 2.65, z), (0.8, 5.3, 0.8), bevel=0.12)
    block(deck, (0, 5.3, 0.5), (9.0, 0.6, 7.0), bevel=0.15)
    hazard_band(yellow, black, (0, 5.3, -3.06), (8.6, 0.5, 0.12), stripe=0.6)
    # Railing (front + -X side), posts in hazard yellow.
    for x in (-4.2, -1.4, 1.4, 4.2):
        bar(yellow, (x, 5.6, -2.7), (x, 7.4, -2.7), 0.22)
    bar(yellow, (-4.3, 7.4, -2.7), (4.3, 7.4, -2.7), 0.26)
    bar(yellow, (-4.3, 6.5, -2.7), (4.3, 6.5, -2.7), 0.18)
    for z in (-2.7, 0.5, 3.7):
        bar(yellow, (-4.2, 5.6, z), (-4.2, 7.4, z), 0.22)
    bar(yellow, (-4.2, 7.4, -2.7), (-4.2, 7.4, 3.7), 0.26)
    # Stairs down to +X (six steps).
    for k in range(6):
        step_h = 5.6 * (6 - k) / 6
        block(deck, (4.9 + 0.75 * k, step_h - 0.2, 2.0), (0.75, 0.4, 2.4), bevel=0.05)
        block(frame, (4.9 + 0.75 * k, (step_h - 0.4) / 2, 3.15), (0.4, max(step_h - 0.4, 0.2), 0.3), bevel=0.04)
    bar(yellow, (4.6, 7.0, 3.3), (9.2, 1.8, 3.3), 0.2)
    for x, y in ((4.6, 5.6), (6.9, 3.0), (9.2, 0.6)):
        bar(yellow, (x, y, 3.3), (x, y + 1.4, 3.3), 0.18)  # handrail posts
    # Office back: desk + BOSS sign board on two posts.
    block(frame, (1.6, 6.5, 2.6), (3.0, 1.8, 1.4), bevel=0.15)
    for s in (-1, 1):
        bar(frame, (s * 2.6, 5.6, 3.7), (s * 2.6, 10.4, 3.7), 0.3)
    sign_frame(frame, sign, (0, 10.2, 3.5), (6.0, 2.0), border=0.4, depth=0.5)
    # The boss at the railing with his megaphone.
    xf = Xf((-1.0, 5.6, -1.3))
    toy_figure(pieces, xf, hat="hardhat", right_arm="megaphone", tie=True)
    # Body-part pieces for the client NPC rig. The torso bone stops at the collar (local y 4.0) so
    # the neck + mouth bars classify with the head; the office pieces never split.
    bones = a4_bones(xf, "down", "megaphone")
    bones["Torso"] = (bones["Torso"][0], xf.p(0.0, 4.0, 0.0))
    rig_split(
        m,
        bones,
        static=("Frame", "Deck", "HazardYellow", "HazardBlack", "Sign"),
        assign={"Megaphone": "ArmR"},
        frame=((-1.0, 5.6, -1.3), 0.0),
    )
    return m


BUILDERS = {
    "A6_Floor": build_floor,
    "A6_EntryArch": build_entry_arch,
    "A6_ShellBack": build_shell_back,
    "A6_ShellSide": build_shell_side,
    "A6_RoofFrame": build_roof_frame,
    "A6_RocketLine": build_rocket_line,
    "A6_Conveyor": build_conveyor,
    "A6_ToyRocket": build_toy_rocket,
    "A6_RobotArm": build_robot_arm,
    "A6_FinPress": build_fin_press,
    "A6_PaintBooth": build_paint_booth,
    "A6_QualityCheck": build_quality_check,
    "A6_Forklift": build_forklift,
    "A6_LoadingDock": build_loading_dock,
    "A6_DeliveryTruck": build_delivery_truck,
    "A6_FactoryBoss": build_factory_boss,
}
