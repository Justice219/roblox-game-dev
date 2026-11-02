"""
area05.py — Area 5 "Enrichment Lab" (spec §3.5): a white / teal clean-room lab with spinning
centrifuges, bubbling glow vats, a computer wall and a head scientist. Every pad purchase is its own
model set so each one builds in separately; placement lives in src/shared/Config/AreaLayouts/Area05.luau.

Shared toy helpers (Xf, toy_figure, _hash, ...) come from area04.py so every figure across areas
4-6 has the same proportions.

Every model has its OWN pivot (ground centre unless stated, front = -Z). The layout places it
with a slot-local CFrame (slot +Z points away from the road, so identity rotation faces the road).
Heights: the yard floor (A5_Floor) tops out at y = 0.4; the clean-room tiles (A5_CleanRoomFloor,
pad 2) add 0.3 inside the lab, so everything bought AFTER pad 2 that stands inside the lab is
placed at y = 0.7 (pads are bought strictly in order, so the tiles always exist by then).

Models (key: pivot / notes)                                          build key
    A5_Floor           slab centre at ground; top y = 0.4                base
    A5_EntryArch       ground centre of the walkway opening; double-    base
                       sided "ENRICHMENT / LAB" block letters (R17)
    A5_LabShell        lab shell centre at ground (x +-44, z +-19):      A5_LabShell
                       open FRONT (pillars, header, cap) + the skylight
                       beam grid with light tubes, no roof
    A5_LabSide         one side wall (two windows), pivot = its ground   A5_LabShell
                       centre; placed twice (yaw 0 at +X, 180 at -X)
    A5_LabBack         back wall (airlock hatch, clerestory windows);    A5_LabShell
                       pivot = the shell centre (same CFrame as A5_LabShell)
    A5_CentrifugeRow   PRODUCER "Centrifuge Row": 3 centrifuges on one   A5_LabShell
                       plinth; RotorLeft / RotorMid / RotorRight at x = -6.5/0/6.5
    A5_CleanRoomFloor  clean-room tiles; pivot = the shell centre        A5_CleanRoomFloor
    A5_Centrifuge      single centrifuge; Rotor on the drum              A5_Centrifuges
    A5_LabCoats        lockers + coat rack + lab bench; back at z = 1.6  A5_LabCoats
    A5_ComputerWall    screen wall + consoles + chairs; back at z = 1.5  A5_ComputerWall
    A5_GlowVat         glass vat of glowing liquid + lid vent stack      A5_GlowVats
    A5_SafetySigns     trefoil / goggles / caution signs + cones         A5_SafetySigns
    A5_HeadScientist   round podium + lectern + the head scientist       A5_HeadScientist

Animation contract = piece NAMES resolved by src/shared/Config/WorldFxConfig.luau (B4). The client
moves each tagged piece about ITS OWN bounding-box centre with a random phase per piece, so:
    Rotor*  (Rotor, RotorLeft, RotorMid, RotorRight) spin about local Y. Each rotor = hub + 4 arms
            + 4 buckets at 90 deg steps, so its bbox centre lies on its spin axis (no wobble).
            Never digit suffixes ("Rotor2"): see the comment in build_centrifuge_row.
    Liquid  (GlowVat) static light-green Smooth + pulsing PointLight at the liquid centre.
    Bubbles (GlowVat) bob +-0.09: they sit on the liquid's surface / outer skin (never fully
            buried in the opaque liquid, never touching the glass).
    Screen / Neon / Potion / Lights / Tubes  static glows (screens, status lights, flask
            contents) — deliberately NOT FX words, so nothing bobs off a wall or out of a flask.

Glow rule (owner R19): Neon only on SMALL accent pieces (largest box face <= 6 studs², see
MeshPlacement.NeonMaxArea: the go-button panel, the hatch "ready" light, the arch beacons, the
status-blinker row, flask contents). Big or spread-out glows (screens, vat liquid, light tubes,
the drum status dots) are authored as Smooth in a light colour (`_lit`), which is exactly what
MeshPlacement.resolveGlow rendered them as anyway — the previews now match the game.

Billboard space (owner R31 / R32): the client puts the producer billboard just in front of the
Centrifuge Row (ProducerBillboards.place) and nudges it toward the road while any visible piece's
BOUNDING BOX overlaps it. A one-piece shell (Wall = side + back + front walls) has a box covering
the whole lab, so the shell is split into A5_LabShell (front + skylight, all above / in front of
the billboard), A5_LabSide x2 and A5_LabBack: no shell piece's box reaches the producer's front.
    Words avoided on purpose: Crystal (-> Glow), Conveyor (-> Belt), Lamp (-> Bulb), Door, any
    name whose leading capitalised word is an FX key.

Z-fighting (owner R18, docs/areas-art.md "Z-fighting layer rule"): trims are proud of what they
frame by >= 0.05 or end inside it, glass edges are buried in their frames, wall pieces of different
models BUTT (side walls own the corners: the back wall, header and their caps / bands stop at the
side walls' inner faces), and nothing shares a top plane along a curve.

Budgets: shell <= 4,500 triangles, machines <= 4,000, props <= 3,000; <= 12 pieces per model.
"""

from __future__ import annotations

import math

from snkit.core import (
    CHARCOAL,
    DEEP_BLUE,
    GLASS,
    GLOW_GREEN,
    GLOW_LIGHT,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LIME,
    Model,
    ORANGE,
    PINK,
    PURPLE,
    STEEL,
    TOY_RED,
    WHITE,
    YELLOW,
)
from snkit.kit import block, disc, hazard_band, hazard_floor, hazard_ring, pipe, sign_frame, trefoil
from snkit.shapes import bar, box, cylinder, ellipsoid, prism, revolve, rot_x, rot_y, rot_z

from models.area01 import sign_text  # shared double-sided block lettering (owner R17)
from models.area04 import Xf, _hash, toy_figure

# ------------------------------------------------------------------------------------------------
# Area-local palette (clean-room lab; the global palette lives in snkit/core.py).
# ------------------------------------------------------------------------------------------------

TEAL = (52, 200, 198)  # lab accent: bands, consoles, lockers
TEAL_DARK = (28, 146, 160)  # frames, beams, pipes
FLOOR_GREY = (216, 224, 230)  # yard slab
TRIM_GREY = (190, 202, 212)  # window frames, cap trims, grout
TILE_MINT = (168, 238, 226)  # clean-room checker tiles
SCREEN_TEAL = (90, 244, 226)  # computer screens (Neon)
HAIR_GREY = (226, 228, 236)  # scientist hair
GOGGLE = (120, 220, 255)  # goggle lenses (Glass)
TUBE_WHITE = (214, 255, 250)  # ceiling light tubes (Neon)
SKIN = (246, 196, 146)  # toy figure skin (same as area 4)



def _lit(rgb, t: float = 0.18):
    """
    `rgb` lifted toward white by `t` (owner R19: big glows are Smooth in a LIGHT colour). The
    default matches MeshPlacement.NeonFallbackLift, so a glow authored with `_lit` looks exactly
    like the lifted Smooth the game rendered for the old over-size Neon piece.
    Example: m.piece("Screen", _lit(SCREEN_TEAL), material="Smooth")
    """
    return tuple(round(c + (255 - c) * t) for c in rgb)


FLOOR_TOP = 0.4  # yard floor top
TILE_TOP = 0.3  # clean-room tiles above the yard floor (models inside the lab sit at 0.7)

# Lab shell box (local to its pivot; the layout places the pivot at slot (0, 0.4, 47)).
SHELL_X = 44.0  # outer half-width
SHELL_Z = 19.0  # outer half-depth
WALL_T = 1.2
WALL_H = 18.0


def _front_disc(piece, center, radius: float, depth: float, segments: int = 16):
    """Flat disc facing -Z (badges, dials, sign faces): a Y-axis revolve turned onto Z."""
    revolve(
        piece,
        [(0.0, -depth / 2), (radius, -depth / 2), (radius, depth / 2), (0.0, depth / 2)],
        center=center,
        segments=segments,
        rot=rot_x(90),
    )


def _rotor(piece, center, arm: float = 1.8, scale: float = 1.0):
    """
    Centrifuge rotor: hub + 4 arms + 4 hanging sample buckets at 90 deg steps. Rotationally
    symmetric about the vertical axis through `center` (bottom of the hub), so the piece's bbox
    centre is on its spin axis — required by WorldFxConfig "Rotor" (spin about own bbox centre).
    """
    cx, cy, cz = center
    cylinder(piece, (cx, cy, cz), (cx, cy + 0.9 * scale, cz), 0.5 * scale, segments=12)
    ellipsoid(piece, (cx, cy + 0.95 * scale, cz), (0.42 * scale, 0.3 * scale, 0.42 * scale), rings=4, segments=12)
    block(piece, (cx, cy + 0.6 * scale, cz), (2 * arm, 0.3 * scale, 0.5 * scale), bevel=0.06)
    block(piece, (cx, cy + 0.6 * scale, cz), (0.5 * scale, 0.3 * scale, 2 * arm), bevel=0.06)
    for dx, dz in ((arm, 0.0), (-arm, 0.0), (0.0, arm), (0.0, -arm)):
        revolve(
            piece,
            [(0.0, 0.0), (0.3 * scale, 0.0), (0.42 * scale, 0.75 * scale), (0.0, 0.75 * scale)],
            center=(cx + dx, cy + 0.1 * scale, cz + dz),
            segments=10,
        )


def _centrifuge_body(housing, band, glass, rotor, neon, x: float, y0: float, radius: float = 2.6, segments: int = 20):
    """
    One centrifuge drum standing at (x, y0, 0): white drum, teal band, yellow rotor on top under a
    glass dome, green status light on the front (into `neon`: a Neon piece for a single drum, the
    Smooth "Lights" piece on the 3-drum row, whose dots span 13 studs — R19). Returns the drum top
    y. `segments` = facets around (the 3-drum producer uses 16 to stay inside its triangle budget).
    """
    r = radius
    top = y0 + 2.9
    revolve(
        housing,
        [(0.0, y0), (r - 0.2, y0), (r, y0 + 0.25), (r, top - 0.3), (r - 0.25, top), (0.0, top)],
        center=(x, 0, 0),
        segments=segments,
    )
    revolve(band, [(r - 0.05, y0 + 1.0), (r + 0.12, y0 + 1.0), (r + 0.12, y0 + 1.6), (r - 0.05, y0 + 1.6)], center=(x, 0, 0), segments=segments, closed=True)
    revolve(band, [(r - 0.6, top - 0.02), (r - 0.05, top - 0.02), (r - 0.05, top + 0.22), (r - 0.6, top + 0.22)], center=(x, 0, 0), segments=segments, closed=True)
    if rotor is not None:  # None: the rotor is a separate placed model (A5_CentrifugeRotor)
        _rotor(rotor, (x, top + 0.05, 0.0), arm=r * 0.66, scale=r / 2.6)
    dome_r = r - 0.3
    revolve(
        glass,
        [(0.0, top + 0.1), (dome_r, top + 0.1), (dome_r, top + 1.1), (dome_r * 0.85, top + 1.8), (dome_r * 0.5, top + 2.25), (0.0, top + 2.4)],
        center=(x, 0, 0),
        segments=segments,
    )
    ellipsoid(neon, (x, y0 + 2.25, -r + 0.02), (0.3, 0.3, 0.16), rings=4, segments=10)
    return top


# ------------------------------------------------------------------------------------------------
# Base: floor + entry arch
# ------------------------------------------------------------------------------------------------

SLOT_W = 104.0
SLOT_D = 70.0


def build_floor():
    """Light lab-yard slab for the whole slot, teal walkway to the lab door, teal pad-strip kerb."""
    m = Model("A5_Floor", "slab centre at ground (place at slot (0, 0, 35)); top y = 0.4", budget=3000)
    slab = m.piece("Slab", FLOOR_GREY)
    path = m.piece("Path", TEAL)
    line = m.piece("Line", WHITE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    # Full slot width (x +-52): the neighbouring rows' floors butt this one edge to edge. At
    # SLOT_W - 0.4 a 0.2-stud strip of plot grass showed between the areas (World-QA, A1-art).
    block(slab, (0, FLOOR_TOP / 2, 0), (SLOT_W, FLOOR_TOP, SLOT_D - 0.4), bevel=0.15)
    # Walkway (slot z 0 -> 28 = local -35 -> -7), white edge lines either side.
    block(path, (0, FLOOR_TOP + 0.05, -21.0), (12.0, 0.1, 28.0), bevel=0.04)
    for s in (-1, 1):
        block(line, (s * 6.3, FLOOR_TOP + 0.06, -21.0), (0.6, 0.12, 28.0), bevel=0.03)
    # Hazard threshold where the walkway meets the lab (slot z ~ 27).
    hazard_floor(yellow, black, (0, FLOOR_TOP + 0.08, -8.6), (12.0, 1.6), 0.12, stripe=0.8)
    # Teal kerb lines behind the pad strip (slot z = 16.5), leaving the walkway open.
    for s in (-1, 1):
        block(path, (s * 29.5, FLOOR_TOP + 0.05, -18.5), (44.0, 0.1, 0.8), bevel=0.03)
    # A few white "clean zone" squares in the yard corners.
    for i, (x, z) in enumerate(((-40, -6), (40, -6), (-40, 20), (40, 20))):
        block(line, (x, FLOOR_TOP + 0.04, z), (5.0, 0.08, 5.0), bevel=0.03, rot=rot_y(10 * (_hash(i, 5) - 0.5)))
    return m


SIGN_Y = 21.4  # arch sign board centre (bottom edge 18.5 sits on the posts)
SIGN_Z = -0.4  # board centre z (the board is 0.7 deep; its panel 0.49)
SIGN_SIZE = (18.0, 5.8)
LETTER_TEAL = TEAL_DARK  # Smooth block letters on the white board (not Neon: R19)


def build_entry_arch():
    """
    White pillars with teal bands, teal beam, DOUBLE-SIDED "ENRICHMENT / LAB" sign (owner R17:
    reads left to right from the road AND from inside the lab yard), trefoil badges, and two small
    Neon beacons on the beam ends. Opening 14 wide x 13 high.

    Z-fighting (R18): the airlock jamb posts sit 0.1 inside the pillar bands' inner faces and their
    own bands are 0.05 proud of the pillar bands, so no two faces share a plane.
    """
    m = Model("A5_EntryArch", "ground centre of the walkway opening; double-sided sign, front -Z (road)", budget=4500)
    pillar = m.piece("Pillar", WHITE)
    band = m.piece("Band", TEAL)
    frame = m.piece("Frame", TEAL_DARK)
    board = m.piece("Board", WHITE, material="Smooth")
    letters = m.piece("Letters", LETTER_TEAL, material="Smooth")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    badge = m.piece("Badge", HAZARD_YELLOW, material="Smooth")
    mark = m.piece("Trefoil", HAZARD_BLACK, material="Smooth")
    # One beacon per piece: each stays a SMALL Neon accent (<= 6 studs² box face, R19); a single
    # piece spanning both beam ends would be 24 studs wide and render as plain Smooth.
    beacons = [m.piece(name, GLOW_GREEN, material="Neon") for name in ("BeaconLeft", "BeaconRight")]
    for s in (-1, 1):
        x = s * 10.0
        block(pillar, (x, 7.0, 0), (6.0, 14.0, 5.6), bevel=0.45)
        for y in (3.2, 11.2):
            block(band, (x, y, 0), (6.3, 1.1, 5.9), bevel=0.15)  # inner face at |x| = 6.85
        block(frame, (x, 14.4, 0), (6.8, 0.9, 6.4), bevel=0.25)
        hazard_band(yellow, black, (x, 0.9, -2.88), (5.6, 1.2, 0.16), stripe=0.7)
        _front_disc(badge, (x, 7.4, -2.86), 1.5, 0.14, segments=18)
        trefoil(mark, (x, 7.4, -2.98), 1.2, 0.08)
        # Inner glass-less "airlock" jamb: slim white post (inner face |x| = 6.95) with a teal
        # stripe (inner face 6.8) — both clear of the pillar bands' 6.85 plane.
        block(pillar, (s * 7.5, 6.6, -1.2), (1.1, 13.2, 1.1), bevel=0.15)
        block(band, (s * 7.5, 6.6, -1.2), (1.4, 0.8, 1.4), bevel=0.08)
    # Beam over the opening + white trim stripe on its front.
    block(band, (0, 16.0, 0), (25.6, 2.2, 4.2), bevel=0.3)
    block(pillar, (0, 15.6, -2.12), (25.0, 0.5, 0.12), bevel=0.04)
    # Beacons resting on the beam ends (beam top y = 17.1), outside the sign (|x| <= 9).
    for s, beacon in zip((-1, 1), beacons):
        ellipsoid(beacon, (s * 11.4, 17.55, 0), (0.6, 0.5, 0.6), rings=5, segments=12)
    # Sign board on short posts above the beam, lettered on BOTH faces (R17; models.area01).
    for s in (-1, 1):
        bar(frame, (s * 6.0, 17.1, SIGN_Z), (s * 6.0, SIGN_Y - SIGN_SIZE[1] / 2 + 0.1, SIGN_Z), 0.5)
    sign_frame(frame, board, (0, SIGN_Y, SIGN_Z), SIGN_SIZE, border=0.6, depth=0.7)
    sign_text(letters, ["ENRICHMENT", "LAB"], (0, SIGN_Y, SIGN_Z), 0.26, 0.22, 0.245)
    return m


# ------------------------------------------------------------------------------------------------
# A5_LabShell: lab building shell + the producer
# ------------------------------------------------------------------------------------------------


CAP_T = 0.6  # top cap trims on every wall: y WALL_H .. CAP_TOP
CAP_TOP = WALL_H + CAP_T  # the skylight beams rest on the caps
SIDE_IN = SHELL_X - WALL_T  # side walls' inner face |x| (back wall / header butt against it)
SIDE_CAP_IN = SHELL_X - WALL_T / 2 - (WALL_T + 0.4) / 2  # side caps' inner face |x| (= 42.6)
SIDE_BAND_IN = SHELL_X - WALL_T / 2 - (WALL_T + 0.3) / 2  # side bands' inner face |x| (= 42.65)
ZB = SHELL_Z - WALL_T / 2  # back wall centre z (shell frame)
ZF = -SHELL_Z + 0.7  # front pillars / header centre z (shell frame)


def _wall_window(trim, glass, center, width: float, height: float, axis: str):
    """
    Glass pane + chunky frame proud of both wall faces (axis "x": wall runs along X).
    Z-fight safe (owner R18 rule 2): the sill's top is 0.1 ABOVE the course under the opening, the
    jambs stand 0.1 proud INTO the opening (outer half buried in the piers), jambs and mullion run
    0.1 into the sill and the head, and the glass edges are buried in all four frame members, so no
    frame face lies on a wall face or on the glass (the old flush sill / jambs / mullion flickered,
    and the mullion top made a curved same-height seam with the glass top).
    """
    cx, cy, cz = center
    t = 0.5
    depth = WALL_T + 0.4
    rise = 0.1
    jamb = width / 2 + t / 2 - rise  # jamb centre offset from the window centre
    head_y = cy + height / 2 + t / 2
    sill_y = cy - height / 2 - t / 2 + rise
    if axis == "x":
        box(glass, (cx, cy, cz), (width, height + 0.1, 0.2))
        block(trim, (cx, head_y, cz), (width + 2 * t, t, depth), bevel=0.1)
        block(trim, (cx, sill_y, cz), (width + 2 * t + 0.6, t, depth + 0.4), bevel=0.1)
        for s in (-1, 1):
            block(trim, (cx + s * jamb, cy, cz), (t, height + 0.2, depth), bevel=0.1)
        block(trim, (cx, cy, cz), (0.3, height + 0.2, 0.5), bevel=0.05)
    else:
        box(glass, (cx, cy, cz), (0.2, height + 0.1, width))
        block(trim, (cx, head_y, cz), (depth, t, width + 2 * t), bevel=0.1)
        block(trim, (cx, sill_y, cz), (depth + 0.4, t, width + 2 * t + 0.6), bevel=0.1)
        for s in (-1, 1):
            block(trim, (cx, cy, cz + s * jamb), (depth, height + 0.2, t), bevel=0.1)
        block(trim, (cx, cy, cz), (0.5, height + 0.2, 0.3), bevel=0.05)


def build_lab_shell():
    """
    Clean-room lab FRONT + roof frame: two pillars under a header beam (open below, so the camera
    and the players walk in), a cap trim on the header, corner hazard plates on the side walls'
    front ends, and the teal skylight beam grid with hanging light tubes resting on the wall caps.
    The walls themselves are A5_LabSide (x2) and A5_LabBack (see the module header: billboard
    space, owner R31 / R32). Same pivot as A5_LabBack and A5_CleanRoomFloor.
    """
    m = Model("A5_LabShell", "shell centre at ground (place at slot (0, 0.4, 47)); front pillars + header at z -19..-17, skylight above", budget=4500)
    wall = m.piece("Wall", WHITE)
    band = m.piece("Band", TEAL)
    trim = m.piece("Trim", TRIM_GREY)
    frame = m.piece("Frame", TEAL_DARK)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    # 28-stud light tubes are a BIG glow: Smooth in a light colour, not Neon (R19).
    tubes = m.piece("Tubes", _lit(TUBE_WHITE), material="Smooth")
    for x in (-22.0, 22.0):
        block(wall, (x, WALL_H / 2, ZF), (2.4, WALL_H, 2.4), bevel=0.3)
        block(band, (x, 2.9, ZF), (2.7, 1.0, 2.7), bevel=0.12)
        hazard_band(yellow, black, (x, 0.75, ZF - 1.28), (2.2, 1.1, 0.14), stripe=0.55)
    # Header: butts the side walls' inner faces (the side walls own the corners), cap on top,
    # teal stripe kept inside the header's length.
    block(wall, (0, 16.8, ZF), (2 * SIDE_IN, 2.4, 1.4), bevel=0.25)
    block(trim, (0, WALL_H + CAP_T / 2, ZF), (2 * SIDE_CAP_IN, CAP_T, 1.8), bevel=0.15)
    block(band, (0, 16.8, ZF - 0.72), (2 * SIDE_IN - 1.6, 0.8, 0.12), bevel=0.04)
    # Hazard plates on the side walls' front end faces (0.01 proud of them).
    for s in (-1, 1):
        hazard_band(yellow, black, (s * (SHELL_X - 0.6), 0.75, -SHELL_Z - 0.08), (1.2, 1.1, 0.14), stripe=0.5)
    # Skylight frame: crosswise beams on the side caps, lengthwise beams on the back cap and the
    # header cap (all bottoms at CAP_TOP = resting contact), light tubes hanging below.
    beam_y = CAP_TOP + 0.5
    for z in (-6.0, 6.0):
        block(frame, (0, beam_y, z), (2 * SHELL_X, 1.0, 1.0), bevel=0.15)
    for x in (-22.0, 0.0, 22.0):
        block(frame, (x, beam_y, 0), (1.0, 1.0, 2 * SHELL_Z), bevel=0.15)
        for z in (-12.0, 12.0):
            bar(frame, (x, CAP_TOP + 0.1, z), (x, WALL_H - 0.9, z), 0.18)
        box(tubes, (x, WALL_H - 1.05, 0), (0.6, 0.35, 28.0))
    return m


def build_lab_side():
    """
    One lab side wall (runs along local Z, 1.2 thick): lower / upper courses, three piers between
    two big framed windows, a teal band and a cap trim. Symmetric in X and Z, so the layout places
    the SAME model twice (yaw 0 at shell x = +43.4, yaw 180 at -43.4): one mesh set, GPU-instanced.
    The side walls own the lab corners: their band and cap run 0.2 past both wall ends, and the
    back wall / header / their caps and bands butt against them.
    """
    m = Model("A5_LabSide", "ground centre of the wall (place at shell x = +-43.4); wall runs along Z, z +-19", budget=2500)
    wall = m.piece("Wall", WHITE)
    band = m.piece("Band", TEAL)
    trim = m.piece("Trim", TRIM_GREY)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    win_lo, win_hi = 6.5, 13.5
    block(wall, (0, win_lo / 2, 0), (WALL_T, win_lo, 2 * SHELL_Z), bevel=0.12)
    block(wall, (0, (win_hi + WALL_H) / 2, 0), (WALL_T, WALL_H - win_hi, 2 * SHELL_Z), bevel=0.12)
    for z0, z1 in ((-SHELL_Z, -14.0), (-3.0, 3.0), (14.0, SHELL_Z)):
        block(wall, (0, (win_lo + win_hi) / 2, (z0 + z1) / 2), (WALL_T, win_hi - win_lo, z1 - z0), bevel=0.12)
    for zc in (-8.5, 8.5):
        _wall_window(trim, glass, (0, (win_lo + win_hi) / 2, zc), 11.0, win_hi - win_lo, "z")
    block(band, (0, 2.9, 0), (WALL_T + 0.3, 1.0, 2 * SHELL_Z + 0.4), bevel=0.1)
    block(trim, (0, WALL_H + CAP_T / 2, 0), (WALL_T + 0.4, CAP_T, 2 * SHELL_Z + 0.4), bevel=0.15)
    return m


def build_lab_back():
    """
    Lab back wall (shell frame, centre z = 18.4): lower course with the airlock opening (x 18..26,
    y 0..9), three clerestory windows, a teal band, a cap trim, and the airlock hatch (two closed
    panels with round portholes, hazard lintel, small green Neon "ready" light). Spans only BETWEEN
    the side walls (|x| <= 42.8); band and cap stop at the side walls' band / cap.
    """
    m = Model("A5_LabBack", "shell centre at ground (same CFrame as A5_LabShell); back wall at z +17.8..+19", budget=3000)
    wall = m.piece("Wall", WHITE)
    band = m.piece("Band", TEAL)
    trim = m.piece("Trim", TRIM_GREY)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    hatch = m.piece("Hatch", TEAL_DARK)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    neon = m.piece("Neon", GLOW_GREEN, material="Neon")  # the small "ready" light only (R19)
    door_x0, door_x1, door_top = 18.0, 26.0, 9.0
    inner = SIDE_IN
    block(wall, ((-inner + door_x0) / 2, 6.0, ZB), (door_x0 + inner, 12.0, WALL_T), bevel=0.12)
    block(wall, ((door_x1 + inner) / 2, 6.0, ZB), (inner - door_x1, 12.0, WALL_T), bevel=0.12)
    block(wall, ((door_x0 + door_x1) / 2, (door_top + 12.0) / 2, ZB), (door_x1 - door_x0, 12.0 - door_top, WALL_T), bevel=0.12)
    edges = [-inner, -36.0, -24.0, -6.0, 6.0, 24.0, 36.0, inner]
    for i in range(0, len(edges) - 1, 2):
        x0, x1 = edges[i], edges[i + 1]
        block(wall, ((x0 + x1) / 2, 14.0, ZB), (x1 - x0, 4.0, WALL_T), bevel=0.12)
    for x0, x1 in ((-36.0, -24.0), (-6.0, 6.0), (24.0, 36.0)):
        _wall_window(trim, glass, ((x0 + x1) / 2, 14.0, ZB), x1 - x0, 4.0, "x")
    block(wall, (0, 17.0, ZB), (2 * inner, 2.0, WALL_T), bevel=0.12)
    # Band: from the side bands' inner face to 0.3 inside the airlock jambs (never flush with the
    # door edge or the jamb faces).
    for x0, x1 in ((-SIDE_BAND_IN, door_x0 - 0.3), (door_x1 + 0.3, SIDE_BAND_IN)):
        block(band, ((x0 + x1) / 2, 2.9, ZB), (x1 - x0, 1.0, WALL_T + 0.3), bevel=0.1)
    block(trim, (0, WALL_H + CAP_T / 2, ZB), (2 * SIDE_CAP_IN, CAP_T, WALL_T + 0.4), bevel=0.15)
    # Airlock hatch: two closed panels (edges buried 0.05 in the jambs) with round portholes
    # 0.1 proud of both panel faces, hazard lintel, green "ready" light.
    for s in (-1, 1):
        xc = 22.0 + s * 2.0
        block(hatch, (xc, door_top / 2, ZB - 0.1), (3.9, door_top, 0.6), bevel=0.12)
        revolve(glass, [(0.0, -0.4), (0.8, -0.4), (0.8, 0.4), (0.0, 0.4)], center=(xc, 6.2, ZB - 0.1), segments=14, rot=rot_x(90))
    # Jambs: inner faces 0.1 proud into the opening, 0.6 proud of the wall front, 0.1 proud behind.
    for s in (-1, 1):
        block(trim, (22.0 + s * 4.2, door_top / 2, ZB - 0.25), (0.6, door_top, WALL_T + 0.7), bevel=0.08)
    hazard_band(yellow, black, (22.0, door_top + 0.5, ZB - 0.72), (9.2, 1.0, 0.16), stripe=0.7)
    ellipsoid(neon, (22.0, door_top + 1.7, ZB - 0.7), (0.5, 0.4, 0.3), rings=4, segments=10)
    return m


# Centrifuge Row drum centres (local x), drum base height and drum top (= rotor pivot height):
# AreaLayouts/Area05.luau places A5_CentrifugeRotor at PRODUCER * (x, ROW_DRUM_TOP, 0).
CENTRIFUGE_ROTOR_X = (-6.5, 0.0, 6.5)
ROW_DRUM_Y0 = 0.8
ROW_DRUM_TOP = ROW_DRUM_Y0 + 2.9


def build_centrifuge_rotor():
    """
    One Centrifuge Row rotor (owner R41): hub + 4 arms + 4 sample buckets, the single piece "Rotor"
    (WorldFx spins it about its own bbox centre, axis Y). Pivot = the drum top centre, so the rotor's
    box centre sits on the dome's vertical axis; it turns inside the glass dome (dome radius 2.3,
    rotor reach 2.14, top 1.3 above the drum vs the dome's 2.4).
    """
    m = Model("A5_CentrifugeRotor", "drum top centre (layout: CentrifugeRow local (x, 3.7, 0)); spins about +Y", budget=600)
    rotor = m.piece("Rotor", YELLOW, material="StudsSmall")
    _rotor(rotor, (0.0, 0.05, 0.0), arm=2.6 * 0.66, scale=1.0)
    return m


def build_centrifuge_row():
    """
    PRODUCER "Centrifuge Row": three centrifuge drums + glass domes on a hazard-banded plinth, a
    teal feed manifold over the domes, a control panel with a screen at the +X end.
    Footprint 21 x 7, manifold top y ~ 8.4.

    The three ROTORS are NOT in this model (owner R41: "this spinner was a bit jacked up"):
    WorldFx moves every piece of one model that resolves to the same row as ONE motion group, so
    three "Rotor*" pieces spun around one leader and the outer two orbited the middle dome. Each
    rotor is its own A5_CentrifugeRotor placement (one mesh, GPU-instanced three times) at
    CENTRIFUGE_ROTORS, so each spins about its own dome's axis.
    """
    m = Model("A5_CentrifugeRow", "ground centre; front -Z; drum tops at local (-6.5 / 0 / 6.5, 3.7, 0) = rotor pivots", budget=4500)
    base = m.piece("Base", STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    housing = m.piece("Housing", WHITE)
    band = m.piece("Band", TEAL)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.5)
    # R19: the control panel (screen + go-button, ~2 x 2 studs) stays a small Neon accent; the
    # three drum status dots are 13 studs apart, so they are Smooth in a light green ("Lights").
    neon = m.piece("Neon", GLOW_GREEN, material="Neon")
    lights = m.piece("Lights", _lit(GLOW_GREEN), material="Smooth")
    block(base, (0, 0.4, 0), (21.0, 0.8, 7.0), bevel=0.2)
    hazard_band(yellow, black, (0, 0.42, -3.56), (20.4, 0.6, 0.14), stripe=0.7)
    tops = []
    for x in CENTRIFUGE_ROTOR_X:
        tops.append(_centrifuge_body(housing, band, glass, None, lights, x, ROW_DRUM_Y0, segments=16))
    # Feed manifold: posts at the ends, a teal pipe over the domes with a drop to each dome.
    for x in (-10.0, 10.0):
        block(base, (x, 4.4, 2.6), (0.8, 8.0, 0.8), bevel=0.1)
    pipe(band, [(-10.0, 8.0, 2.6), (-10.0, 8.0, 0.0), (10.0, 8.0, 0.0), (10.0, 8.0, 2.6)], 0.38, segments=10)
    for x, top in zip((-6.5, 0.0, 6.5), tops):
        cylinder(band, (x, 8.0, 0.0), (x, top + 2.35, 0.0), 0.26, segments=8)
        disc(band, (x, top + 2.25, 0.0), 0.5, 0.25, segments=10, bevel=0.06)
    # Control panel at the +X end: slanted desk, green screen, big green go-button.
    block(base, (9.9, 1.9, -1.6), (1.2, 3.0, 2.4), bevel=0.15)
    block(base, (9.9, 3.5, -1.7), (1.5, 0.4, 2.8), bevel=0.08, rot=rot_x(-20))
    block(neon, (9.9, 3.72, -1.8), (1.1, 0.06, 1.6), rot=rot_x(-20))
    ellipsoid(neon, (9.9, 2.2, -2.85), (0.35, 0.35, 0.18), rings=4, segments=10)
    return m


# ------------------------------------------------------------------------------------------------
# Pads
# ------------------------------------------------------------------------------------------------


def build_clean_room_floor():
    """
    Raised clean-room tiles (white / mint checker on light-grey grout) filling the lab interior
    (x +-42.6, z -18.6..17.6 around the shell pivot), hazard strip along the open front.
    Top y = 0.3 above the yard floor.
    """
    m = Model("A5_CleanRoomFloor", "lab shell centre at ground (same pivot as A5_LabShell); tile top y = 0.3", budget=4500)
    grout = m.piece("Grout", TRIM_GREY)
    white = m.piece("TileWhite", WHITE)
    mint = m.piece("TileMint", TILE_MINT)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    z0, z1 = -18.6, 17.6
    block(grout, (0, 0.075, (z0 + z1) / 2), (85.2, 0.15, z1 - z0), bevel=0.04)
    cols, rows = 12, 5
    pitch_x = 84.0 / cols
    pitch_z = (z1 - z0) / rows
    for i in range(cols):
        for j in range(rows):
            x = -42.0 + pitch_x * (i + 0.5)
            z = z0 + pitch_z * (j + 0.5)
            piece = white if (i + j) % 2 == 0 else mint
            block(piece, (x, 0.225, z), (pitch_x - 0.3, 0.15, pitch_z - 0.3), bevel=0.05)
    hazard_floor(yellow, black, (0, 0.33, z0 + 0.7), (84.0, 1.0), 0.06, stripe=1.0)
    return m


def build_centrifuge():
    """Single big centrifuge: hazard-ringed base, white drum, Rotor under a glass dome, control box."""
    m = Model("A5_Centrifuge", "ground centre; front -Z; Rotor axis at local (0, *, 0)", budget=3000)
    base = m.piece("Base", STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    housing = m.piece("Housing", WHITE)
    band = m.piece("Band", TEAL)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.5)
    neon = m.piece("Neon", GLOW_GREEN, material="Neon")
    rotor = m.piece("Rotor", YELLOW, material="StudsSmall")
    disc(base, (0, 0, 0), 3.2, 0.5, segments=20, bevel=0.12)
    hazard_ring(yellow, black, (0, 0, 0), 2.75, 3.25, 0.48, 0.62, count=14)
    _centrifuge_body(housing, band, glass, rotor, neon, 0.0, 0.5, radius=2.7)
    # Control box on the front with a dial.
    block(band, (0, 2.0, -2.85), (1.8, 1.4, 0.6), bevel=0.12)
    _front_disc(base, (0, 2.0, -3.18), 0.42, 0.1, segments=12)
    return m


def build_lab_coats():
    """Four teal lockers, a coat rack with three white lab coats, a lab bench with glowing flasks."""
    m = Model("A5_LabCoats", "ground centre; front -Z; back face at local z = +1.6 (flush to a wall)", budget=3000)
    white = m.piece("White", WHITE)
    locker = m.piece("Locker", TEAL)
    rack = m.piece("Rack", STEEL, material="StudsSmall")
    top = m.piece("Top", TEAL_DARK)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.4)
    potion = m.piece("Potion", PINK, material="Neon")
    potion_b = m.piece("PotionB", LIME, material="Neon")
    # Lockers (x -9 .. -2.6): white carcass + teal doors with vents and handles.
    block(white, (-5.8, 3.3, 0.6), (6.6, 6.6, 2.0), bevel=0.18)
    for k in range(4):
        x = -8.2 + k * 1.6
        block(locker, (x, 3.2, -0.42), (1.45, 6.0, 0.1), bevel=0.04)
        for y in (5.6, 5.2, 4.8):
            block(rack, (x, y, -0.5), (0.9, 0.12, 0.06))
        block(rack, (x + 0.5, 3.2, -0.52), (0.14, 0.7, 0.1), bevel=0.03)
    # Coat rack (x -2 .. 3): two posts + rail + three hanging lab coats.
    for x in (-1.9, 2.9):
        block(rack, (x, 0.15, 0.4), (1.0, 0.3, 1.0), bevel=0.06)
        bar(rack, (x, 0.3, 0.4), (x, 6.6, 0.4), 0.2)
    bar(rack, (-1.9, 6.4, 0.4), (2.9, 6.4, 0.4), 0.16)
    # Teal backboard behind the coats: white coats vanish against the lab's white walls without it.
    block(locker, (0.5, 4.5, 1.42), (5.2, 4.6, 0.24), bevel=0.08)
    for x in (-0.9, 0.5, 1.9):
        bar(rack, (x, 6.4, 0.4), (x, 6.0, 0.4), 0.08)
        block(white, (x, 4.6, 0.4), (1.3, 2.7, 0.45), bevel=0.12)  # coat body
        block(white, (x, 5.85, 0.4), (1.5, 0.35, 0.55), bevel=0.08)  # shoulders / collar
        for s in (-1, 1):
            block(white, (x + s * 0.72, 4.75, 0.4), (0.32, 2.1, 0.42), bevel=0.06, rot=rot_z(s * 6))
        block(locker, (x, 4.9, 0.16), (0.36, 0.42, 0.06))  # teal pocket
    # Lab bench (x 3.6 .. 9): top + lower shelf + legs; flasks and a test-tube rack.
    block(top, (6.3, 3.1, 0.3), (5.4, 0.3, 2.4), bevel=0.08)
    block(top, (6.3, 1.0, 0.3), (5.0, 0.2, 2.0), bevel=0.05)
    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(rack, (6.3 + sx * 2.5, 0.0, 0.3 + sz * 1.0), (6.3 + sx * 2.5, 2.95, 0.3 + sz * 1.0), 0.16)
    for x, z, h, piece in ((4.5, 0.0, 1.3, potion), (6.0, 0.6, 1.1, potion_b), (8.4, -0.2, 1.4, potion)):
        revolve(glass, [(0.0, 0.0), (0.55, 0.0), (0.62, 0.1), (0.24, h * 0.7), (0.2, h), (0.0, h)], center=(x, 3.25, z), segments=12)
        revolve(piece, [(0.0, 0.02), (0.5, 0.02), (0.36, h * 0.4), (0.0, h * 0.4)], center=(x, 3.25, z), segments=12)
    block(rack, (7.2, 3.45, 0.9), (1.6, 0.2, 0.6), bevel=0.04)
    # Test tubes all lime: a pink tube at the back would stretch the pink Potion piece's box past
    # the 6 studs² Neon limit (R19) and turn every pink flask into plain Smooth.
    for k in range(3):
        x = 6.7 + k * 0.5
        cylinder(glass, (x, 3.4, 0.9), (x, 4.4, 0.9), 0.14, segments=8)
        cylinder(potion_b, (x, 3.45, 0.9), (x, 3.9, 0.9), 0.11, segments=8)
    return m


def build_computer_wall():
    """
    Screen wall (six bezelled glowing screens with dark chart bars) over a teal console desk.
    R19: the six screens (18 x 6 studs together) are a BIG glow, so they are Smooth in a light teal
    (the keyboard status LEDs share that piece); the status-blinker row along the top is the one
    small Neon accent (16.5 x 0.3 studs, under the 6 studs² limit).
    """
    m = Model("A5_ComputerWall", "ground centre; front -Z; back face at local z = +1.5 (flush to a wall)", budget=3500)
    cabinet = m.piece("Cabinet", WHITE)
    console = m.piece("Console", TEAL)
    bezel = m.piece("Bezel", CHARCOAL, material="StudsSmall")
    screen = m.piece("Screen", _lit(SCREEN_TEAL), material="Smooth")
    neon = m.piece("Neon", GLOW_GREEN, material="Neon")
    chair = m.piece("Chair", TOY_RED)
    block(cabinet, (0, 5.2, 1.0), (20.0, 10.4, 1.0), bevel=0.2)
    block(console, (0, 10.6, 0.9), (20.4, 0.7, 1.6), bevel=0.15)
    for col, x in enumerate((-6.3, 0.0, 6.3)):
        for row, y in enumerate((4.9, 8.4)):
            block(bezel, (x, y, 0.32), (5.8, 3.2, 0.36), bevel=0.1)
            box(screen, (x, y, 0.1), (5.1, 2.6, 0.12))
            seed = col * 2 + row
            if seed == 3:  # the big middle-top screen shows a trefoil
                trefoil(bezel, (x, y, -0.02), 1.0, 0.06)
                continue
            # Dark chart bars on the glowing screen (deterministic heights).
            for k in range(6):
                h = 0.5 + 1.6 * _hash(seed, k)
                block(bezel, (x - 2.0 + k * 0.8, y - 1.15 + h / 2, -0.02), (0.42, h, 0.06))
    # Status blinkers along the top.
    for k in range(9):
        block(neon, (-8.0 + k * 2.0, 10.1, 0.4), (0.5, 0.3, 0.12), bevel=0.04)
    # Console desk + slanted control strip with keyboards.
    block(cabinet, (0, 1.3, -0.9), (18.0, 2.6, 2.6), bevel=0.2)
    block(console, (0, 2.8, -1.1), (18.6, 0.4, 3.2), bevel=0.12)
    for x in (-6.0, 0.0, 6.0):
        block(bezel, (x, 3.08, -1.6), (3.0, 0.16, 1.0), bevel=0.04, rot=rot_x(-8))
        ellipsoid(screen, (x + 2.0, 3.1, -1.5), (0.22, 0.12, 0.22), rings=3, segments=8)
    # Two office chairs.
    for x in (-4.0, 4.0):
        block(bezel, (x, 0.12, -4.4), (1.8, 0.24, 1.8), bevel=0.06, rot=rot_y(45))
        cylinder(bezel, (x, 0.2, -4.4), (x, 1.7, -4.4), 0.16, segments=8)
        block(chair, (x, 1.9, -4.4), (1.8, 0.4, 1.8), bevel=0.15)
        block(chair, (x, 3.0, -3.6), (1.8, 2.0, 0.35), bevel=0.12)
    return m


def build_glow_vat():
    """
    Bubbling glow vat: hazard-ringed steel base, glass tank of glowing Liquid with Bubbles on its
    surface / skin, teal lid and struts, a vent stack on the lid (top y ~ 10.9).
    """
    m = Model("A5_GlowVat", "ground centre; front -Z (gauge); vent stack top y ~ 10.9", budget=3000)
    base = m.piece("Base", STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    # R19: a 4-stud tank of liquid is a BIG glow: Smooth in a light green, lit by its WorldFx
    # "Liquid" PointLight; the bubbles cluster spans the tank, so it is Smooth too.
    liquid = m.piece("Liquid", _lit(GLOW_GREEN), material="Smooth")
    bubbles = m.piece("Bubbles", _lit(GLOW_LIGHT), material="Smooth")
    cap = m.piece("Cap", TEAL)
    disc(base, (0, 0, 0), 2.9, 0.7, segments=20, bevel=0.15)
    hazard_ring(yellow, black, (0, 0, 0), 2.5, 2.95, 0.68, 0.82, count=14)
    revolve(glass, [(0.0, 0.8), (2.2, 0.8), (2.2, 6.8), (0.0, 6.8)], segments=20)
    revolve(liquid, [(0.0, 0.85), (2.0, 0.85), (2.0, 5.55), (1.7, 5.72), (0.0, 5.78)], segments=16)
    # Bubbles: half-sunk in the liquid's outer skin and floating just above its surface, so the
    # +-0.09 bob always shows (the liquid is opaque) and never touches the glass.
    for k in range(7):
        a = 2 * math.pi * k / 7 + 0.4
        y = 1.6 + 0.6 * k
        r = 0.2 + 0.06 * _hash(k, 3)
        ellipsoid(bubbles, (1.88 * math.cos(a), y, 1.88 * math.sin(a)), (r, r, r), rings=4, segments=8)
    for k, (x, z, r) in enumerate(((0.4, -0.5, 0.32), (-0.7, 0.3, 0.26), (0.9, 0.8, 0.22), (-0.2, 1.1, 0.18))):
        ellipsoid(bubbles, (x, 5.95 + 0.25 * (k % 2), z), (r, r, r), rings=4, segments=8)
    # Lid, collar and four struts outside the glass.
    revolve(cap, [(2.0, 0.78), (2.45, 0.78), (2.45, 1.2), (2.0, 1.2)], segments=20, closed=True)
    revolve(cap, [(0.0, 6.75), (2.45, 6.75), (2.45, 7.25), (1.6, 7.6), (0.0, 7.7)], segments=20)
    for k in range(4):
        a = math.radians(45 + 90 * k)
        bar(cap, (2.35 * math.cos(a), 1.0, 2.35 * math.sin(a)), (2.35 * math.cos(a), 7.0, 2.35 * math.sin(a)), 0.22)
    # Vent stack on the lid (self-contained, so a vat can stand anywhere, e.g. in front of a window).
    cylinder(cap, (0.0, 7.5, 0.0), (0.0, 10.4, 0.0), 0.36, segments=10)
    revolve(cap, [(0.0, 10.3), (0.75, 10.3), (0.9, 10.55), (0.5, 10.85), (0.0, 10.9)], segments=10)
    revolve(cap, [(0.36, 8.8), (0.56, 8.8), (0.56, 9.1), (0.36, 9.1)], segments=10, closed=True)
    # Little gauge on the base front.
    _front_disc(base, (0, 1.6, -2.3), 0.45, 0.12, segments=12)
    return m


def build_safety_signs():
    """
    Safety corner: yellow trefoil warning triangle, round "goggles on" sign, caution A-frame,
    three traffic cones and a hazard floor patch. ~12 wide.
    """
    m = Model("A5_SafetySigns", "ground centre; signs face -Z; floor patch at y = 0..0.1", budget=3000)
    post = m.piece("Post", STEEL, material="StudsSmall")
    board = m.piece("Board", HAZARD_YELLOW)
    ink = m.piece("Ink", HAZARD_BLACK, material="Smooth")
    white = m.piece("White", WHITE)
    teal = m.piece("Teal", TEAL)
    cone = m.piece("Cone", ORANGE)
    # Hazard floor patch under the group (yellow stripes over the ink colour).
    hazard_floor(board, ink, (0, 0.05, 0.4), (11.0, 3.0), 0.1, stripe=0.9)
    # 1) Trefoil warning triangle on a post (x = -4).
    disc(post, (-4.0, 0.1, 0.8), 0.7, 0.3, segments=12, bevel=0.08)
    cylinder(post, (-4.0, 0.4, 0.8), (-4.0, 5.2, 0.8), 0.16, segments=8)
    tri = [(-4.0 + 2.2 * math.cos(math.radians(a)), 5.4 + 2.2 * math.sin(math.radians(a)), 0.6) for a in (90, 210, 330)]
    prism(board, tri, (0, 0, 1), 0.25)
    prism(ink, [(p[0], 5.4 + (p[1] - 5.4) * 1.12, p[2] + 0.05) for p in tri], (0, 0, 1), 0.12)
    trefoil(ink, (-4.0, 5.1, 0.45), 0.85, 0.06)
    # 2) Round "goggles on" sign (x = 0.2): white face, teal ring, black goggles icon.
    disc(post, (0.2, 0.1, 1.0), 0.7, 0.3, segments=12, bevel=0.08)
    cylinder(post, (0.2, 0.4, 1.0), (0.2, 5.0, 1.0), 0.16, segments=8)
    _front_disc(teal, (0.2, 5.6, 0.82), 1.8, 0.2, segments=20)
    _front_disc(white, (0.2, 5.6, 0.7), 1.45, 0.08, segments=20)
    for s in (-1, 1):
        revolve(ink, [(0.32, -0.04), (0.52, -0.04), (0.52, 0.04), (0.32, 0.04)], center=(0.2 + s * 0.6, 5.6, 0.62), segments=12, rot=rot_x(90), closed=True)
    block(ink, (0.2, 5.6, 0.62), (0.35, 0.12, 0.06))
    for s in (-1, 1):
        block(ink, (0.2 + s * 1.25, 5.62, 0.62), (0.4, 0.14, 0.06))
    # 3) Caution A-frame (x = 3.8): two leaning yellow boards with a black "!" on the front one.
    # The "!" is laid out in the FRONT board's own frame (same tilt about the board centre), its
    # back 0.01 inside the board and its face 0.05 proud. Tilting each ink block about its own
    # centre left the bar 0.005 behind the board face (z-fight, R18) and the dot floating.
    for s in (-1, 1):
        block(board, (3.8, 1.25, 0.3 + s * 0.42), (1.8, 2.5, 0.16), bevel=0.06, rot=rot_x(s * 12))
    tilt = math.radians(-12)
    front = (1.25, 0.3 - 0.42)  # front board centre (y, z)
    ink_z = -0.08 - 0.02  # board half-thickness 0.08, ink centre 0.02 further out (ink is 0.06)
    for ly, size in ((0.3, (0.28, 1.0, 0.06)), (-0.5, (0.3, 0.28, 0.06))):
        # rot_x: (y, z) -> (y cos - z sin, y sin + z cos), about the board centre.
        y = front[0] + ly * math.cos(tilt) - ink_z * math.sin(tilt)
        z = front[1] + ly * math.sin(tilt) + ink_z * math.cos(tilt)
        block(ink, (3.8, y, z), size, bevel=0.0, rot=rot_x(-12))
    # Three traffic cones with white bands.
    for k, (x, z) in enumerate(((5.6, -0.7), (-1.9, -0.6), (-5.8, -0.4))):
        block(cone, (x, 0.12, z), (1.4, 0.24, 1.4), bevel=0.06)
        revolve(cone, [(0.0, 0.24), (0.6, 0.24), (0.14, 2.0), (0.0, 2.05)], center=(x, 0, z), segments=12)
        revolve(white, [(0.47, 0.75), (0.53, 0.75), (0.36, 1.25), (0.3, 1.25)], center=(x, 0, z), segments=12, closed=True)
    return m


def build_head_scientist():
    """
    The head scientist (lab coat, wild hair, goggles, clipboard) on a round podium with a lectern.

    Animated NPC (owner R30): the figure is split into rig pieces (Torso*/Head*/ArmL*/ArmR*/LegL*/
    LegR*, see models/_npc_rig.py) so the client ManagerController can walk her around the podium
    top, swing her limbs, wave (raises the relaxed left arm) and tap the lectern. Podium + lectern
    use their own pieces (White, Trim, Badge, Beaker, Potion) and never move; the figure's coat,
    clipboard board and goggles are separate pieces (Coat, Board, Goggles).
    """
    from models._npc_rig import a4_bones, rig_split

    m = Model("A5_HeadScientist", "ground centre of the podium; scientist faces -Z; podium top y = 0.8", budget=3500)
    white = m.piece("White", WHITE)
    trim = m.piece("Trim", TEAL_DARK)
    badge = m.piece("Badge", HAZARD_YELLOW, material="Smooth")
    glass = m.piece("Goggles", GOGGLE, material="Glass", transparency=0.3)
    beaker = m.piece("Beaker", GOGGLE, material="Glass", transparency=0.3)
    potion = m.piece("Potion", PURPLE, material="Neon")
    coat = m.piece("Coat", WHITE)
    pieces = {
        "skin": m.piece("Skin", SKIN, material="StudsSmall"),
        "shirt": coat,
        "coat": coat,
        "pants": m.piece("Pants", DEEP_BLUE, material="StudsSmall"),
        "dark": m.piece("Dark", CHARCOAL, material="Smooth"),
        "hat": m.piece("Hair", HAIR_GREY, material="StudsSmall"),
        "goggles": glass,
        "board": m.piece("Board", TEAL_DARK),
        "paper": coat,
    }
    pieces["hair"] = pieces["hat"]
    # Podium: white drum with a teal rim and a trefoil badge on the front.
    disc(white, (0, 0, 0), 2.8, 0.8, segments=20, bevel=0.2)
    revolve(trim, [(2.7, 0.55), (2.9, 0.55), (2.9, 0.85), (2.7, 0.85)], segments=20, closed=True)
    _front_disc(badge, (0, 0.42, -2.78), 0.36, 0.1, segments=12)
    trefoil(pieces["dark"], (0, 0.42, -2.86), 0.3, 0.05)
    # Lectern beside him with a bubbling beaker.
    block(trim, (1.9, 0.95, -0.6), (1.4, 0.3, 1.4), bevel=0.06)
    block(white, (1.9, 2.3, -0.6), (0.7, 2.5, 0.7), bevel=0.1)
    block(trim, (1.9, 3.65, -0.7), (1.8, 0.3, 1.5), bevel=0.06, rot=rot_x(-12))
    revolve(beaker, [(0.0, 0.0), (0.42, 0.0), (0.42, 1.0), (0.5, 1.08), (0.0, 1.08)], center=(1.9, 3.82, -0.7), segments=12)
    revolve(potion, [(0.0, 0.02), (0.36, 0.02), (0.36, 0.6), (0.0, 0.6)], center=(1.9, 3.82, -0.7), segments=12)
    xf = Xf((-0.6, 0.8, 0.2))
    toy_figure(pieces, xf, hat="hair", right_arm="clipboard", coat=True)
    # Body-part pieces for the client NPC rig (podium + lectern pieces stay static props; the
    # podium trefoil in "Dark" is ~2.6 studs from every bone, so it stays a static "Dark" island).
    # The torso's classification segment stops at shoulder height (joint unchanged) so the mouth
    # bars + neck join the head instead of tying with the torso.
    bones = a4_bones(xf, "down", "clipboard")
    bones["Torso"] = (bones["Torso"][0], xf.p(0.0, 4.1, 0.0))
    rig_split(
        m,
        bones,
        static=("White", "Trim", "Badge", "Beaker", "Potion"),
        assign={"Board": "ArmR"},
        frame=((-0.6, 0.8, 0.2), 0.0),
    )
    return m


BUILDERS = {
    "A5_Floor": build_floor,
    "A5_EntryArch": build_entry_arch,
    "A5_LabShell": build_lab_shell,
    "A5_LabSide": build_lab_side,
    "A5_LabBack": build_lab_back,
    "A5_CentrifugeRow": build_centrifuge_row,
    "A5_CentrifugeRotor": build_centrifuge_rotor,
    "A5_CleanRoomFloor": build_clean_room_floor,
    "A5_Centrifuge": build_centrifuge,
    "A5_LabCoats": build_lab_coats,
    "A5_ComputerWall": build_computer_wall,
    "A5_GlowVat": build_glow_vat,
    "A5_SafetySigns": build_safety_signs,
    "A5_HeadScientist": build_head_scientist,
}
