"""
area07.py — Area 7 "Launch Silos" set (spec §3.7): a hazard-striped launch field with three candy
cartoon nukes standing in stud gantry frames, a spinning radar dish, a mission-control room, the
level-1 AA Tower and the Attack Console (the two Feature pads that switch Attack mode on, spec §9).

Kid-friendly rules baked in (spec §1): the nukes are chunky candy TOYS (red/black, mint/black,
white/gold) with a glowing green core band and a plain radiation-trefoil badge (no faces, no flags,
no real-world markings); the AA turret is a candy-striped toy cannon.

SLOT FRAME (docs/superpowers/plans/2026-10-30-sellnukes-build.md "World layout"):
    origin = slot road-side edge midpoint at ground (y = 0), +Z away from the road, +X along it.
    Slot x in [-52, 52], z in [0, 70], height budget 80. Pads sit in the road strip z in [2, 16].
    The area deck top is DECK_TOP = 0.5; every prop below is placed ON the deck (pivot y = 0.5).

Model keys (layout: src/shared/Config/AreaLayouts/Area07.luau places them; all front = -Z = road):
    SLOT-ORIGIN pivot (place at the slot origin, CFrame.identity):
        A7_Deck           slate stud deck panels (104 x 70), side/back curbs, light walkway      (base)
        A7_HazardFloor    hazard lanes, cross band, walkway chevrons, bollards, loading zone      (A7_HazardFloor)
    OWN pivot = ground centre (place at (x, DECK_TOP, z)):
        A7_EntryArch      banded hazard pillars, lettered "LAUNCH SILOS" sign, mini nukes          (base)
        A7_SiloBase       18 x 18 launch platform, silo collar, 4-post stud gantry, ladder, beacons (silo builds)
        A7_SiloNuke_Red   24-stud cartoon nuke, red body / black bands       ANIMATABLE (launch)
        A7_SiloNuke_Mint  mint body / black bands                             ANIMATABLE (launch)
        A7_SiloNuke_Gold  white body / gold bands + gold nose                 ANIMATABLE (launch)
                          nuke pivot = centre under the fins on the platform top (silo pivot + (0, 1.2, 0));
                          nose tip at pivot + (0, 24, 0) = the attack-mode launch point.
        A7_RadarDish      lattice pylon + motor drum; piece `Dish` ROTATES about the pivot's vertical axis
        A7_ControlRoom    blue mission-control block, window onto glowing screens; piece `Door` slides
                          +X by DOOR_SLIDE (4.4) to open; lettered "CONTROL" sign
        A7_LaunchDirector friendly headset robot with a clipboard (Manager)
        A7_AATower        AA Tower BASE: 14 x 14 hazard plinth (top y = 1.0), corner beacons, "AA DEFENSE"
                          placard. B8f's levelled AATower1..5 stand on it (layout aaTowerMount).
        A7_AttackConsole  big-red-button console; piece Screen (its -Z face may take the target-picker
                          SurfaceGui), lettered "ATTACK!" sign

Budgets (docs/world-art.md §4): landmarks <= 6,000 tris, machines <= 3,000-4,500, props <= 1,500-2,500.
Colours come from snkit.core; area-local accents are defined below.

Piece names drive client animation (src/shared/Config/WorldFxConfig.luau resolves names, MeshLibrary
tags them): `Dish` oscillates about Y through the PIECE'S OWN bounding-box centre, `Core` / `Bulb`
get a pulsing light, `Glow` bobs, `Belt` scrolls, `Nuke*` bobs, `Wheel` spins. So static glowing
detail is never called `Glow` here (`ScreenGlow`), and the radar's Dish carries a counterweight
that centres its bounding box on the rotation axis.
"""

import math

import bmesh
from mathutils import Matrix, Vector

from models.area01 import FONT_ROWS, block_text, text_cells
from snkit.core import (
    CHARCOAL,
    CONCRETE,
    CONCRETE_DARK,
    CREAM,
    DARK_STEEL,
    DEEP_BLUE,
    GLASS,
    GLOW_GREEN,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    MINT,
    Model,
    ORANGE,
    SIDEWALK,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    WHITE,
    WOOD,
    rb,
)
from snkit.kit import block, disc, hazard_band, hazard_floor, ladder, nuke_body, sign_frame, trefoil
from snkit.shapes import bar, box, cylinder, ellipsoid, extrude_outline, prism, revolve, rot_x

# ------------------------------------------------------------------------------------------------
# Area constants (mirrored in src/shared/Config/AreaLayouts/Area07.luau — keep both in sync)
# ------------------------------------------------------------------------------------------------

DECK_TOP = 0.5  # walk surface of the area deck (slot-local y)
SLOT_W, SLOT_D = 104.0, 70.0  # slot footprint x in [-52, 52], z in [0, 70]
SLOT_PIVOT = "slot origin (road-side edge midpoint, ground y = 0); +Z away from the road; place at CFrame.identity"

PLAT, PLAT_TOP = 18.0, 1.2  # silo platform size and its top height above the deck
POST, FRAME_TOP = 7.4, 30.0  # gantry corner-post centres (+-POST) and frame top height
NUKE_LEN, NUKE_R = 24.0, 3.8  # silo nuke length (base -> nose tip) and chubby body radius

CR_W, CR_D, CR_FLOOR, CR_TOP = 24.0, 14.0, 0.6, 11.0  # control room footprint, floor, wall top
DOOR_SLIDE = 4.4  # control-room door slide distance (+X) when open

# Area-local accents (not in the shared palette): slate launch deck like the reference field,
# gold trim for the white/gold nuke, cyan robot eyes, dark "screen glass" blue.
SLATE = (104, 112, 146)
GOLD = (255, 190, 40)
CYAN = (120, 230, 255)
SCREEN_BLUE = (40, 70, 170)


# ------------------------------------------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------------------------------------------


def sign_text(piece, lines, center, size, border, depth, letter_depth=0.25, pad=0.3, both_sides=False):
    """
    Bake brick-pixel letters (models.area01 font, readable from the road) onto a sign_frame panel
    built with the SAME center / size / border / depth. The cell size is the largest that fits the
    panel's inner area; letters sit on the panel's -Z face and extrude `letter_depth` toward -Z.
    bevel=0 keeps a word at ~12 triangles per block (bevels are invisible at this size).

    both_sides=True (owner R17, arch signs seen from the road AND from inside the area) adds a copy
    on the +Z face: the -Z letters ROTATED 180 deg about the sign's vertical axis (a rotation, not a
    mirror), so a viewer behind the sign also reads them left to right.

    Example: sign_frame(red, sign, (0, 19.4, -0.3), (18.4, 4.0), 0.55, 0.7)
             sign_text(letters, "LAUNCH SILOS", (0, 19.4, -0.3), (18.4, 4.0), 0.55, 0.7, both_sides=True)
    """
    if isinstance(lines, str):
        lines = [lines]
    inner_w = size[0] - 2 * border - 2 * pad
    inner_h = size[1] - 2 * border - 2 * pad
    cols = max(text_cells(line) for line in lines)
    rows = len(lines) * FONT_ROWS + (len(lines) - 1) * 2
    cell = min(inner_w / cols, inner_h / rows)
    cx, cy, cz = center
    bm = piece.bm
    first = len(bm.verts)
    block_text(piece, lines, (cx, cy, cz - depth * 0.35), cell, letter_depth, bevel=0.0)
    if both_sides:
        # Second pass, then turn ONLY its vertices half a turn about the panel's vertical axis
        # (Roblox +Y = Blender +Z), which moves them onto the +Z face reading correctly from there.
        mark = len(bm.verts)
        block_text(piece, lines, (cx, cy, cz - depth * 0.35), cell, letter_depth, bevel=0.0)
        bm.verts.ensure_lookup_table()
        bmesh.ops.rotate(bm, cent=rb((cx, cy, cz)), matrix=Matrix.Rotation(math.pi, 3, "Z"), verts=bm.verts[mark:])
    assert len(bm.verts) > first, "sign_text produced no letters"
    return cell


def _hazard_border(yellow, black, center_xz, size_xz, width, y_top, stripe=1.4, thick=0.12):
    """
    Hazard-striped border strips around a rectangle lying on a surface whose top is `y_top`.
    The strips sink 0.04 into the surface (no z-fighting, no visible gap) and rise `thick - 0.04`.

    Example: _hazard_border(y, b, (0, 0), (18, 18), 1.8, 1.2)  # border on a silo platform top
    """
    cx, cz = center_xz
    sx, sz = size_xz
    cy = y_top - 0.04 + thick / 2
    hazard_floor(yellow, black, (cx, cy, cz - sz / 2 + width / 2), (sx, width), thick, stripe=stripe)
    hazard_floor(yellow, black, (cx, cy, cz + sz / 2 - width / 2), (sx, width), thick, stripe=stripe)
    hazard_floor(yellow, black, (cx - sx / 2 + width / 2, cy, cz), (width, sz - 2 * width), thick, stripe=stripe)
    hazard_floor(yellow, black, (cx + sx / 2 - width / 2, cy, cz), (width, sz - 2 * width), thick, stripe=stripe)


def _banded_post(yellow, black, center_xz, y0, y1, size, band=1.75):
    """
    Square post made of stacked alternating yellow/black chamfered blocks (chunky hazard pillar,
    like the striped gantry posts in docs/reference/missiles-vs-cities/19-*.png).
    """
    x, z = center_xz
    y, i = y0, 0
    while y < y1 - 1e-6:
        h = min(band, y1 - y)
        block(yellow if i % 2 == 0 else black, (x, y + h / 2, z), (size, h, size), bevel=0.12)
        y += h
        i += 1


def _lattice_tower(legs, braces, half0, half1, y0, y1, levels, member=0.45):
    """
    Four-leg tapered lattice tower (radar pylon, AA tower). Corner legs run from half-width
    `half0` at y0 to `half1` at y1; every level gets a horizontal ring and an X-brace per face.
    Legs + end rings go into `legs`, intermediate rings + braces into `braces` (two-tone mast).
    Cost: (4 + 4*(levels+1) + 8*levels) bars x 12 triangles.
    """
    signs = ((-1, -1), (1, -1), (1, 1), (-1, 1))

    def corner(k, t):
        h = half0 + (half1 - half0) * t
        return (signs[k][0] * h, y0 + (y1 - y0) * t, signs[k][1] * h)

    for k in range(4):
        bar(legs, corner(k, 0.0), corner(k, 1.0), member)
    for i in range(levels + 1):
        t = i / levels
        ring = legs if i in (0, levels) else braces
        for k in range(4):
            bar(ring, corner(k, t), corner((k + 1) % 4, t), member * 0.8)
        if i < levels:
            t2 = (i + 1) / levels
            for k in range(4):
                bar(braces, corner(k, t), corner((k + 1) % 4, t2), member * 0.55)
                bar(braces, corner((k + 1) % 4, t), corner(k, t2), member * 0.55)


def _badge(badge, mark, center_y, radius, body_r, front_offset=0.0):
    """
    Yellow radiation badge (plain trefoil, no face) on the -Z side of a round body of radius
    body_r. The disc is thick enough that its back edge stays buried in the curved body while its
    face sits just proud of the surface (a flat disc on a cylinder would float at its edges).
    """
    edge_z = -math.sqrt(max(body_r * body_r - radius * radius, 0.01))  # body surface at the disc rim
    front = -body_r - 0.08 - front_offset
    back = edge_z + 0.12
    half = (back - front) / 2
    cz = (front + back) / 2
    # rot_x(90) maps the revolve axis (local +Y) onto world +Z, so local -y is the -Z face.
    revolve(
        badge,
        [(0.0, -half), (radius * 0.9, -half), (radius, -half + 0.14), (radius, half), (0.0, half)],
        center=(0, center_y, cz),
        segments=20,
        rot=rot_x(90),
    )
    trefoil(mark, (0, center_y, front - 0.04), radius * 0.8, 0.08, normal=(0, 0, -1))


# ------------------------------------------------------------------------------------------------
# Base (built by A7_EntryArch, the Area 6 unlock pad)
# ------------------------------------------------------------------------------------------------


def build_deck():
    """Slate launch-field deck in 16 chamfered panels (the seams read as steel plates), curbs, walkway."""
    m = Model("A7_Deck", SLOT_PIVOT + "; deck top y = 0.5", budget=2500)
    deck = m.piece("Deck", SLATE)
    curb = m.piece("Curb", CONCRETE)
    walk = m.piece("Walk", SIDEWALK)
    cols, rows = 4, 4
    pw, pd = SLOT_W / cols, SLOT_D / rows
    for i in range(cols):
        for j in range(rows):
            x = -SLOT_W / 2 + pw * (i + 0.5)
            z = pd * (j + 0.5)
            block(deck, (x, 0.15, z), (pw, 0.7, pd), bevel=0.14)  # y -0.2 .. 0.5
    # Curbs on the back and both sides (the road side stays open). Top y = 1.0.
    block(curb, (0, 0.65, SLOT_D - 0.6), (SLOT_W, 0.7, 1.2), bevel=0.14)
    for s in (-1, 1):
        block(curb, (s * (SLOT_W / 2 - 0.6), 0.65, SLOT_D / 2 - 0.6), (1.2, 0.7, SLOT_D - 1.2), bevel=0.14)
    # Light walkway from the arch to the main silo's front step (z 0 .. 41), raised 0.08.
    block(walk, (0, 0.52, 20.5), (12.0, 0.12, 41.0), bevel=0.02)
    return m


def build_entry_arch():
    """Two banded hazard pillars, beam, lettered "LAUNCH SILOS" sign, mini candy nukes on its corners."""
    m = Model("A7_EntryArch", "ground centre between the pillars (deck top); walk through toward +Z; Sign faces -Z", budget=4000)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    steel = m.piece("Steel", DARK_STEEL)
    red = m.piece("Red", TOY_RED)
    sign = m.piece("Sign", CREAM)
    nose = m.piece("Nose", WHITE)
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    letters = m.piece("Letters", HAZARD_BLACK, material="Smooth")
    px = 7.6  # pillar centre x (opening 12.6 wide; pads start at x = +-13.5)
    for s in (-1, 1):
        block(steel, (s * px, 0.5, 0), (3.4, 1.0, 3.4), bevel=0.2)
        _banded_post(yellow, black, (s * px, 0), 1.0, 15.0, 2.6)
        block(steel, (s * px, 15.4, 0), (3.2, 0.8, 3.2), bevel=0.2)
    block(steel, (0, 16.6, 0), (19.6, 1.6, 2.2), bevel=0.2)
    hazard_band(yellow, black, (0, 16.6, -1.15), (19.0, 1.0, 0.15), stripe=0.9)
    # Lettered area-name sign on the beam (warning-sign look: black letters, cream panel, red frame).
    sign_c, sign_size = (0, 19.4, -0.3), (18.4, 4.0)
    sign_frame(red, sign, sign_c, sign_size, border=0.55, depth=0.7)
    sign_text(letters, "LAUNCH SILOS", sign_c, sign_size, 0.55, 0.7, both_sides=True)  # R17: both faces
    # Mini candy nukes on steel caps at the sign's top corners, red beacon in the middle.
    for s in (-1, 1):
        block(steel, (s * px, 21.6, -0.3), (2.6, 0.4, 2.6), bevel=0.1)
        nuke_body(red, nose, black, core, base=(s * px, 21.8, -0.3), length=5.0, radius=1.0, segments=14)
    block(steel, (0, 21.55, -0.3), (1.2, 0.3, 1.2), bevel=0.08)
    ellipsoid(beacon, (0, 22.1, -0.3), (0.45, 0.55, 0.45), rings=5, segments=10)
    return m


# ------------------------------------------------------------------------------------------------
# Silos (A7_SiloPad = producer silo, A7_Silo2, A7_Silo3)
# ------------------------------------------------------------------------------------------------


# Silo nuke fins (snkit.kit.nuke_body with fin_count 4): angles in degrees (Roblox x = cos, z = sin)
# and half their tangential thickness (max(0.24, NUKE_R * 0.4) / 2), for the collar notches.
FIN_ANGLES = (45.0, 135.0, 225.0, 315.0)
FIN_HALF = max(0.24, 3.8 * 0.4) / 2


def _notched_collar(yellow, black, r_in, r_out, y0, y1, count=16, slices=2, clearance=0.15):
    """
    The silo's striped collar ring (snkit.kit.hazard_ring layout: `count` alternating segments)
    with a NOTCH at every fin of the standing nuke, so the fins drop into the collar instead of
    cutting through it (owner R24: no interpenetration; check_area_overlaps.py). A notch is the
    fin's tangential half-thickness + `clearance`, measured at the ring's inner radius.

    Example: _notched_collar(yellow, black, 5.1, 6.2, PLAT_TOP - 0.05, PLAT_TOP + 0.3)
    """
    half = math.degrees(math.asin(min(1.0, (FIN_HALF + clearance) / r_in)))
    gaps = [(a - half, a + half) for a in FIN_ANGLES]
    step = 360.0 / count
    for i in range(count):
        piece = yellow if i % 2 == 0 else black
        spans = [(i * step, (i + 1) * step)]
        for g0, g1 in gaps:
            cut = []
            for a0, a1 in spans:
                if g1 <= a0 or g0 >= a1:
                    cut.append((a0, a1))
                    continue
                if a0 < g0:
                    cut.append((a0, g0))
                if g1 < a1:
                    cut.append((g1, a1))
            spans = cut
        for a0, a1 in spans:
            if a1 - a0 < 0.5:
                continue  # sliver left beside a notch
            n = max(1, round(slices * (a1 - a0) / step))
            angles = [math.radians(a0 + (a1 - a0) * k / n) for k in range(n + 1)]
            outer = [(r_out * math.cos(a), r_out * math.sin(a)) for a in angles]
            inner = [(r_in * math.cos(a), r_in * math.sin(a)) for a in reversed(angles)]
            extrude_outline(piece, outer + inner, y0, y1)


def build_silo_base():
    """
    18 x 18 launch platform with a hazard border and a striped silo collar around a dark shaft,
    framed by a 4-post stud gantry (open toward the road so the nuke reads), with a service arm,
    a ladder and red beacons on the post tops. The nuke models stand at pivot + (0, PLAT_TOP, 0).
    """
    m = Model("A7_SiloBase", "ground centre of the platform (deck top); open side -Z; nuke stands at (0, 1.2, 0)", budget=4500)
    plinth = m.piece("Plinth", CONCRETE_DARK)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    shaft = m.piece("Shaft", CHARCOAL)
    frame = m.piece("Frame", STEEL)
    beams = m.piece("Beams", DARK_STEEL)
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    block(plinth, (0, PLAT_TOP / 2, 0), (PLAT, PLAT_TOP, PLAT), bevel=0.24)
    block(plinth, (0, 0.4, -PLAT / 2 - 0.9), (6.0, 0.8, 1.8), bevel=0.16)  # front step
    _hazard_border(yellow, black, (0, 0), (PLAT - 0.6, PLAT - 0.6), 1.8, PLAT_TOP, stripe=1.4)
    # Silo shaft opening + striped collar ring the nuke stands in.
    disc(shaft, (0, PLAT_TOP - 0.1, 0), 5.2, 0.2, segments=24, bevel=0.05)
    _notched_collar(yellow, black, 5.1, 6.2, PLAT_TOP - 0.05, PLAT_TOP + 0.3, count=16)
    # Four corner posts + top ring beams; mid beams on the back and sides only (front stays open).
    post_h = FRAME_TOP - PLAT_TOP
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(frame, (sx * POST, PLAT_TOP + post_h / 2, sz * POST), (1.7, post_h, 1.7), bevel=0.2)
            ellipsoid(beacon, (sx * POST, FRAME_TOP + 0.35, sz * POST), (0.5, 0.5, 0.5), rings=5, segments=10)
    # Top ring beams: 0.1 below the post tops and ending inside the posts (never flush: R18 z-fight).
    top_y = FRAME_TOP - 0.85
    for s in (-1, 1):
        block(beams, (0, top_y, s * POST), (2 * POST + 1.5, 1.5, 1.4), bevel=0.15)
        block(beams, (s * POST, top_y, 0), (1.4, 1.5, 2 * POST), bevel=0.15)
    for y in (11.0, 20.5):
        block(beams, (0, y, POST), (2 * POST, 1.1, 1.1), bevel=0.12)
        for s in (-1, 1):
            block(beams, (s * POST, y, 0), (1.1, 1.1, 2 * POST), bevel=0.12)
    # Diagonal braces on the side faces (one per bay, alternating) for the gantry read.
    bays = ((PLAT_TOP, 11.0), (11.0, 20.5), (20.5, top_y))
    for s in (-1, 1):
        for i, (ya, yb) in enumerate(bays):
            za, zb = (-POST, POST) if i % 2 == 0 else (POST, -POST)
            bar(beams, (s * POST, ya, za), (s * POST, yb, zb), 0.55)
    # Service arm reaching to the nuke from the back beam, hazard-striped tip.
    block(beams, (0, 20.5, (POST + NUKE_R + 0.6) / 2), (1.2, 1.0, POST - NUKE_R - 0.6), bevel=0.12)
    block(yellow, (0, 20.5, NUKE_R + 0.35), (1.6, 1.3, 0.5), bevel=0.1)
    # Ladder up the back of the right rear post.
    ladder(frame, (POST, PLAT_TOP, POST + 1.25), FRAME_TOP - PLAT_TOP - 1.0, width=1.3, rung_step=1.0, rail=0.2)
    return m


def _build_silo_nuke(key, body_color, trim_color, nose_color):
    """
    The silo's cartoon nuke (24 studs, chunky, stud material): candy body, contrasting bands +
    fins + nozzle (Trim), nose cone, glowing core band, yellow trefoil badge on the -Z face.
    The WHOLE model is the animatable "Nuke": tween its pivot up for a launch.
    """
    m = Model(key, "centre under the fins (silo platform top); nose up, tip at y = 24; badge faces -Z", budget=2600)
    body = m.piece("Body", body_color)
    trim = m.piece("Trim", trim_color)
    nose = trim if nose_color == trim_color else m.piece("Nose", nose_color)
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    badge = m.piece("Badge", HAZARD_YELLOW, material="Smooth")
    mark = m.piece("Trefoil", HAZARD_BLACK, material="Smooth")
    core_y = nuke_body(body, nose, trim, core, base=(0, 0, 0), length=NUKE_LEN, radius=NUKE_R, fin_count=4, segments=20)
    # Bands (same maths as snkit.kit.nuke_body: body starts at 0.098 L and is 0.62 L long).
    body_y0 = NUKE_LEN * 0.28 * 0.35
    body_len = NUKE_LEN * 0.62
    for t in (0.1, 0.74, 0.97):
        y = body_y0 + body_len * t
        revolve(
            trim,
            [(NUKE_R * 0.97, y - 0.55), (NUKE_R * 1.07, y - 0.45), (NUKE_R * 1.07, y + 0.45), (NUKE_R * 0.97, y + 0.55)],
            segments=20,
            closed=True,
        )
    _badge(badge, mark, core_y + 3.5, 2.0, NUKE_R)
    return m


def build_silo_nuke_red():
    return _build_silo_nuke("A7_SiloNuke_Red", TOY_RED, HAZARD_BLACK, WHITE)


def build_silo_nuke_mint():
    return _build_silo_nuke("A7_SiloNuke_Mint", MINT, HAZARD_BLACK, WHITE)


def build_silo_nuke_gold():
    return _build_silo_nuke("A7_SiloNuke_Gold", WHITE, GOLD, GOLD)


# ------------------------------------------------------------------------------------------------
# Radar dish (A7_RadarDish)
# ------------------------------------------------------------------------------------------------


def build_radar_dish():
    """
    Hazard plinth, tapered lattice pylon, motor drum and the rotating dish assembly. EVERYTHING in
    the `Dish` piece (turntable, yoke, bowl, feed struts, horn) spins together about the vertical
    axis through the pivot (x = 0, z = 0); the bowl faces -Z tilted 25 deg up at rest.
    """
    m = Model("A7_RadarDish", "ground centre (deck top); piece Dish rotates about the pivot's Y axis", budget=4000)
    plinth = m.piece("Plinth", CONCRETE_DARK)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    pylon = m.piece("Pylon", STEEL)
    braces = m.piece("Braces", WHITE)
    housing = m.piece("Housing", DEEP_BLUE)
    dish = m.piece("Dish", WHITE, material="StudsSmall")
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    block(plinth, (0, 0.5, 0), (10.0, 1.0, 10.0), bevel=0.2)
    _hazard_border(yellow, black, (0, 0), (9.6, 9.6), 1.4, 1.0, stripe=1.1)
    _lattice_tower(pylon, braces, 3.4, 1.8, 1.0, 15.0, levels=3, member=0.5)
    block(housing, (0, 15.4, 0), (5.6, 0.8, 5.6), bevel=0.15)
    cylinder(housing, (0, 15.8, 0), (0, 17.4, 0), 1.6, segments=16)
    for sx in (-1, 1):
        for sz in (-1, 1):
            ellipsoid(beacon, (sx * 2.4, 16.15, sz * 2.4), (0.32, 0.38, 0.32), rings=4, segments=8)
    # --- rotating assembly (Dish piece) ---
    disc(dish, (0, 17.4, 0), 2.0, 0.5, segments=16, bevel=0.12)
    cylinder(dish, (0, 17.9, 0), (0, 20.6, 0), 0.7, segments=12)
    axis = Vector((0.0, math.sin(math.radians(25)), -math.cos(math.radians(25))))
    vertex = Vector((0.0, 22.4, 0.9))
    cylinder(dish, (0, 20.4, 0), tuple(vertex + axis * 0.2), 0.75, segments=12)  # yoke to bowl back
    k, rim, thick = 0.09, 5.6, 0.45  # paraboloid y = k r^2, rim radius, shell thickness
    radii = (0.0, 1.4, 2.8, 4.2, rim)
    front = [(r, k * r * r) for r in radii]
    back = [(r, k * r * r - thick) for r in reversed(radii)]
    profile = [(0.0, 0.0)] + front[1:] + [(rim + 0.15, k * rim * rim - thick * 0.5)] + back[:-1] + [(0.0, -thick)]
    revolve(dish, profile, center=tuple(vertex), segments=20, rot=rot_x(-65))  # rot_x(-65): +Y -> axis
    depth = k * rim * rim
    feed = vertex + axis * (depth + 1.6)
    side = Vector((1.0, 0.0, 0.0))
    up = axis.cross(side).normalized()
    for ang in (90.0, 210.0, 330.0):
        a = math.radians(ang)
        p = vertex + axis * depth + (side * math.cos(a) + up * math.sin(a)) * (rim - 0.2)
        bar(dish, tuple(p), tuple(feed), 0.28)
    cylinder(dish, tuple(feed - axis * 0.7), tuple(feed + axis * 0.5), 0.5, segments=10, radius_b=0.7)
    # Counterweight behind the yoke. WorldFx rotates a MeshPart about its own bounding-box centre,
    # and the bowl alone spans z -4.03 .. +2.0; this block's back face at z = +4.05 puts the piece's
    # XZ centre on the pivot axis (verify: MeshAssets.A7_RadarDish.pieces.Dish.offset x, z ~ 0).
    bar(dish, (0, 19.4, 0.4), (0, 19.4, 2.3), 0.55)
    block(dish, (0, 19.4, 3.1), (1.8, 1.5, 1.9), bevel=0.2)
    return m


# ------------------------------------------------------------------------------------------------
# Control room (A7_ControlRoom)
# ------------------------------------------------------------------------------------------------


def _cr_window(trim, glass, x0, x1, y0, y1, z, mullions=()):
    """
    Front window (wall runs along X): glass pane, chunky white frame, deep sill, mullions at x.
    Z-fight safe (owner R18): the glass edges run 0.1 into the frame, the header hangs 0.1 below
    the wall cut, the sill top stands 0.3 above it and the side posts are 0.06 proud of the jambs.
    """
    w, h = x1 - x0, y1 - y0
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    box(glass, (cx, cy, z), (w + 0.2, h + 0.2, 0.2))
    block(trim, (cx, y1 + 0.15, z), (w + 0.8, 0.5, 1.3), bevel=0.1)  # header: y1 - 0.1 .. y1 + 0.4
    block(trim, (cx, y0 + 0.05, z - 0.25), (w + 1.2, 0.5, 1.8), bevel=0.1)  # sill: y0 - 0.2 .. y0 + 0.3
    for s in (-1, 1):
        # 0.06 into the opening, and running 0.2 up into the header (tops never flush with walls).
        block(trim, (cx + s * (w / 2 + 0.17), cy + 0.1, z), (0.46, h + 0.2, 1.3), bevel=0.08)
    for mx in mullions:
        block(trim, (mx, cy, z), (0.3, h, 0.6), bevel=0.05)


# Control-room front layout (local x): the door sits at the LEFT end so it can slide +X into a
# solid wall pocket; one big window on the right shows the consoles and wall screens.
CR_DOOR_X0, CR_DOOR_X1 = -10.4, -6.0  # door opening (4.4 wide = DOOR_SLIDE)
CR_WIN_X0, CR_WIN_X1 = -0.8, 10.6  # big window
CR_WIN_Y0, CR_WIN_Y1 = 3.6, 8.6
CR_DOOR_TOP = 8.6


def build_control_room():
    """
    Mission-control block facing the road: blue walls with a hazard skirt, one big window onto
    glowing consoles and wall screens, a yellow sliding `Door` at the left end (it slides +X by
    DOOR_SLIDE into the solid wall pocket, never over the glass), a lettered "CONTROL" sign, roof
    antenna with a beacon. Not enterable (collision is one box); the interior reads through glass.
    """
    m = Model("A7_ControlRoom", "ground centre (deck top); door + window face -Z; Door slides +X 4.4 to open", budget=5000)
    walls = m.piece("Walls", DEEP_BLUE)
    trim = m.piece("Trim", WHITE)
    roof = m.piece("Roof", DARK_STEEL)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.4)
    door = m.piece("Door", HAZARD_YELLOW)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    screens = m.piece("Screens", SKY_BLUE, material="Neon")
    glow = m.piece("ScreenGlow", GLOW_GREEN, material="Neon")  # not "Glow": WorldFx would bob it
    desk = m.piece("Desk", CHARCOAL)
    sign = m.piece("Sign", CREAM)
    red = m.piece("Red", TOY_RED)
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    hw, hd = CR_W / 2, CR_D / 2
    zf = -hd + 0.5  # front wall centre plane (wall spans z -7 .. -6)
    block(roof, (0, CR_FLOOR / 2, 0), (CR_W + 1.0, CR_FLOOR, CR_D + 1.0), bevel=0.12)

    def wall(x0, x1, y0, y1):
        box(walls, ((x0 + x1) / 2, (y0 + y1) / 2, zf), (x1 - x0, y1 - y0, 1.0))

    # Front wall: left jamb, door pocket wall (door slides into it), window band, right jamb, header.
    wall(-hw, CR_DOOR_X0, CR_FLOOR, CR_DOOR_TOP)
    wall(CR_DOOR_X1, CR_WIN_X0, CR_FLOOR, CR_DOOR_TOP)
    wall(CR_WIN_X0, CR_WIN_X1, CR_FLOOR, CR_WIN_Y0)
    wall(CR_WIN_X1, hw, CR_FLOOR, CR_DOOR_TOP)
    wall(-hw, hw, CR_DOOR_TOP, CR_TOP)
    _cr_window(trim, glass, CR_WIN_X0, CR_WIN_X1, CR_WIN_Y0, CR_WIN_Y1, zf, mullions=(3.0, 6.8))
    skirt_x0 = CR_DOOR_X1 + 0.6
    hazard_band(yellow, black, ((skirt_x0 + hw - 0.6) / 2, 1.7, -hd - 0.08), (hw - 0.6 - skirt_x0, 1.6, 0.2), stripe=0.9)
    # Back + side walls (solid), white corner posts.
    box(walls, (0, (CR_FLOOR + CR_TOP) / 2, hd - 0.5), (CR_W, CR_TOP - CR_FLOOR, 1.0))
    for s in (-1, 1):
        box(walls, (s * (hw - 0.5), (CR_FLOOR + CR_TOP) / 2, 0), (1.0, CR_TOP - CR_FLOOR, CR_D - 2.0))
        hazard_band(yellow, black, (s * (hw + 0.08), 1.7, 0), (CR_D - 1.6, 1.6, 0.2), stripe=0.9, axis="z")
        for sz in (-1, 1):
            # Corner posts run 0.3 up INTO the roof slab: their tops never sit flush with the walls' (R18).
            post_top = CR_TOP + 0.3
            block(trim, (s * (hw - 0.3), (CR_FLOOR + post_top) / 2, sz * (hd - 0.3)), (1.3, post_top - CR_FLOOR, 1.3), bevel=0.18)
    # Door frame + the sliding Door (centred in the wall plane, so it slides into the wall pocket).
    door_cx = (CR_DOOR_X0 + CR_DOOR_X1) / 2
    door_w = CR_DOOR_X1 - CR_DOOR_X0
    # Jambs stand 0.06 into the opening and the header hangs 0.1 below it (R18: never flush).
    for x in (CR_DOOR_X0 - 0.22, CR_DOOR_X1 + 0.22):
        jamb_top = CR_DOOR_TOP + 0.3  # runs up into the door header trim
        block(trim, (x, (CR_FLOOR + jamb_top) / 2, zf - 0.1), (0.56, jamb_top - CR_FLOOR, 1.3), bevel=0.08)
    block(trim, (door_cx, CR_DOOR_TOP + 0.2, zf - 0.1), (door_w + 1.0, 0.6, 1.3), bevel=0.08)
    block(door, (door_cx, (CR_FLOOR + CR_DOOR_TOP) / 2, zf), (door_w - 0.1, CR_DOOR_TOP - CR_FLOOR - 0.05, 0.6), bevel=0.1)
    for y in (2.6, 4.6, 6.6):
        block(door, (door_cx, y, zf - 0.35), (door_w - 1.0, 0.3, 0.2), bevel=0.05)
    # Roof slab + white parapet cap, lettered "CONTROL" sign over the window.
    block(roof, (0, CR_TOP + 0.5, 0), (CR_W + 1.2, 1.0, CR_D + 1.2), bevel=0.2)
    block(trim, (0, CR_TOP + 1.15, -hd - 0.3), (CR_W + 1.4, 0.5, 0.7), bevel=0.12)
    block(trim, (0, CR_TOP + 1.15, hd + 0.3), (CR_W + 1.4, 0.5, 0.7), bevel=0.12)
    for s in (-1, 1):
        block(trim, (s * (hw + 0.3), CR_TOP + 1.15, 0), (0.7, 0.5, CR_D + 0.6), bevel=0.12)
    letters = m.piece("Letters", HAZARD_BLACK, material="Smooth")
    sign_c, sign_size = ((CR_WIN_X0 + CR_WIN_X1) / 2, 9.8, -hd - 0.15), (10.0, 2.2)
    sign_frame(red, sign, sign_c, sign_size, border=0.32, depth=0.4)
    sign_text(letters, "CONTROL", sign_c, sign_size, 0.32, 0.4, letter_depth=0.18, pad=0.15)
    # Interior (seen through the window): a long console with glowing keys, three wall screens.
    block(desk, ((CR_WIN_X0 + CR_WIN_X1) / 2, CR_FLOOR + 1.3, zf + 1.7), (CR_WIN_X1 - CR_WIN_X0 - 0.6, 2.6, 1.6), bevel=0.15)
    for i in range(8):
        block(glow, (CR_WIN_X0 + 1.2 + i * 1.35, CR_FLOOR + 2.66, zf + 1.6), (0.7, 0.12, 0.5), bevel=0.04)
    for x in (-4.0, 2.4, 8.8):
        block(desk, (x, 6.6, hd - 1.1), (5.6, 3.6, 0.3), bevel=0.08)
        box(screens, (x, 6.6, hd - 1.3), (5.0, 3.0, 0.12))
        box(glow, (x, 6.6, hd - 1.38), (3.2, 0.12, 0.06))
        box(glow, (x - 0.8, 6.9, hd - 1.38), (0.12, 1.6, 0.06))
    # Roof antenna mast with a little static dish and a beacon; AC box.
    cylinder(trim, (7.0, CR_TOP + 1.0, 3.0), (7.0, CR_TOP + 6.5, 3.0), 0.22, segments=8)
    revolve(trim, [(0.0, 0.0), (1.0, 0.25), (1.2, 0.5), (1.1, 0.6), (0.0, 0.3)], center=(7.0, CR_TOP + 4.0, 2.6), segments=12, rot=rot_x(-60))
    ellipsoid(beacon, (7.0, CR_TOP + 6.8, 3.0), (0.35, 0.4, 0.35), rings=4, segments=8)
    block(trim, (-6.5, CR_TOP + 1.8, 2.5), (4.0, 1.6, 3.0), bevel=0.2)
    block(roof, (-6.5, CR_TOP + 2.65, 2.5), (2.4, 0.15, 2.4), bevel=0.04)
    return m


# ------------------------------------------------------------------------------------------------
# Hazard floor (A7_HazardFloor) — slot-origin overlay on the deck
# ------------------------------------------------------------------------------------------------


def _bollard(yellow, black, x, z):
    """Short hazard bollard: yellow post, black band, rounded cap."""
    cylinder(yellow, (x, DECK_TOP, z), (x, DECK_TOP + 2.2, z), 0.45, segments=10)
    cylinder(black, (x, DECK_TOP + 1.4, z), (x, DECK_TOP + 1.8, z), 0.5, segments=10)
    ellipsoid(yellow, (x, DECK_TOP + 2.2, z), (0.45, 0.3, 0.45), rings=4, segments=10)


def _barrel(body, band, x, z):
    """Chunky fuel barrel (charcoal) with two yellow hoops."""
    cylinder(body, (x, DECK_TOP, z), (x, DECK_TOP + 2.6, z), 1.0, segments=12)
    for y in (0.7, 1.9):
        cylinder(band, (x, DECK_TOP + y - 0.15, z), (x, DECK_TOP + y + 0.15, z), 1.06, segments=12)


def build_hazard_floor():
    """
    Painted hazard markings over the deck: striped lanes along the walkway, a cross band in front
    of the silo row, yellow chevrons pointing at the main silo, bollards and a striped loading
    zone (front right) with fuel barrels. Everything is 0.08-0.12 thick on top of the deck.
    """
    m = Model("A7_HazardFloor", SLOT_PIVOT + "; markings sit on the deck top y = 0.5", budget=3500)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    barrels = m.piece("Barrels", CHARCOAL)
    y = DECK_TOP + 0.07  # 0.51 .. 0.63: clears the walkway top (0.58) where the band crosses it
    for s in (-1, 1):  # lanes z 17..35 BUTT the cross band (z 35..38): overlapping stripes z-fight
        hazard_floor(yellow, black, (s * 7.5, y, 26.0), (2.0, 18.0), 0.12, stripe=1.6)
    # Cross band in front of the silo row; 68 wide so it never overlaps the loading-zone border.
    hazard_floor(yellow, black, (0, y, 36.5), (68.0, 3.0), 0.12, stripe=2.0)
    # Chevrons on the walkway (two parallelograms each), pointing +Z at the producer silo.
    for zc in (19.0, 25.0, 31.0):
        for s in (-1, 1):
            pts = [(s * 0.2, zc + 1.2), (s * 3.6, zc - 1.2), (s * 3.6, zc - 2.6), (s * 0.2, zc - 0.2)]
            prism(yellow, [(px, DECK_TOP + 0.1, pz) for px, pz in pts], (0, 1, 0), 0.12)
    for z in (18.0, 26.0, 34.0):
        for s in (-1, 1):
            _bollard(yellow, black, s * 9.2, z)
    # Loading zone (front right, right of the launch director): striped border + barrels.
    _hazard_border(yellow, black, (43.0, 29.0), (14.0, 14.0), 1.6, DECK_TOP, stripe=1.4)
    for bx, bz in ((40.0, 26.0), (42.4, 26.4), (41.2, 28.4), (45.6, 31.6), (46.0, 25.4)):
        _barrel(barrels, yellow, bx, bz)
    return m


# ------------------------------------------------------------------------------------------------
# Launch Director (Manager robot)
# ------------------------------------------------------------------------------------------------


def build_launch_director():
    """
    Friendly launch-director robot (~8.6 studs): white body with orange accents, cyan eyes on a
    dark visor, a headset with a mic boom, antenna bulb, clipboard in the left hand, right arm
    relaxed at its side.

    Animated NPC (owner R30): split into rig pieces (Torso*/Head*/ArmL*/ArmR*/LegL*/LegR*, see
    models/_npc_rig.py) so the client ManagerController walks it, swings its limbs, waves and does
    the "3, 2, 1 ... confetti!" launch chop with the free right arm (the old static pointing-up
    pose is now the client's wave / work motion). The clipboard rides the left arm.
    """
    from models._npc_rig import rig_split

    m = Model("A7_LaunchDirector", "ground centre between the feet (deck top); faces -Z", budget=2500)
    body = m.piece("Body", WHITE, material="StudsSmall")
    accent = m.piece("Accent", ORANGE, material="StudsSmall")
    dark = m.piece("Dark", CHARCOAL, material="StudsSmall")
    visor = m.piece("Visor", DEEP_BLUE, material="Smooth")
    eyes = m.piece("Eyes", CYAN, material="Neon")
    board = m.piece("Clipboard", WOOD, material="StudsSmall")
    paper = m.piece("Paper", WHITE, material="Smooth")
    bulb = m.piece("Bulb", TOY_RED, material="Neon")
    # Feet + legs
    for s in (-1, 1):
        block(accent, (s * 0.8, 0.35, -0.2), (1.2, 0.7, 1.9), bevel=0.2)
        cylinder(dark, (s * 0.8, 0.7, 0), (s * 0.8, 2.5, 0), 0.38, segments=10)
    # Torso + chest panel with glowing buttons
    block(body, (0, 4.0, 0), (3.2, 3.2, 2.2), bevel=0.45, segments=2)
    block(accent, (0, 4.2, -1.12), (1.9, 1.3, 0.2), bevel=0.08)
    for i, x in enumerate((-0.5, 0.0, 0.5)):
        block(eyes if i != 1 else bulb, (x, 4.2, -1.27), (0.32, 0.32, 0.14), bevel=0.05)
    block(accent, (0, 2.55, 0), (3.0, 0.5, 2.0), bevel=0.15)  # belt
    # Neck + head + visor + eyes + smile
    cylinder(dark, (0, 5.6, 0), (0, 6.1, 0), 0.5, segments=10)
    block(body, (0, 7.2, 0), (2.9, 2.3, 2.5), bevel=0.55, segments=2)
    block(visor, (0, 7.25, -1.24), (2.3, 1.4, 0.18), bevel=0.25, segments=2)
    for s in (-1, 1):
        block(eyes, (s * 0.55, 7.45, -1.36), (0.45, 0.6, 0.1), bevel=0.15, segments=2)
    for x0, y0, x1, y1 in ((-0.55, 6.95, -0.2, 6.78), (-0.2, 6.78, 0.2, 6.78), (0.2, 6.78, 0.55, 6.95)):
        bar(eyes, (x0, y0, -1.37), (x1, y1, -1.37), 0.1)
    # Headset: band over the head, ear cups, mic boom to the mouth
    for x0, y0, x1, y1 in ((-1.55, 7.6, -1.1, 8.55), (-1.1, 8.55, 1.1, 8.55), (1.1, 8.55, 1.55, 7.6)):
        bar(dark, (x0, y0, 0), (x1, y1, 0), 0.28)
    for s in (-1, 1):
        cylinder(dark, (s * 1.45, 7.3, 0), (s * 1.75, 7.3, 0), 0.6, segments=12)
    bar(dark, (-1.65, 7.0, -0.2), (-0.9, 6.7, -1.45), 0.14)
    ellipsoid(dark, (-0.75, 6.7, -1.5), (0.22, 0.22, 0.22), rings=4, segments=8)
    # Antenna + bulb
    cylinder(dark, (0, 8.35, 0.3), (0, 9.5, 0.3), 0.09, segments=6)
    ellipsoid(bulb, (0, 9.65, 0.3), (0.28, 0.3, 0.28), rings=4, segments=8)
    # Arms: shoulders, right arm relaxed at its side, left arm holding the clipboard
    for s in (-1, 1):
        ellipsoid(accent, (s * 1.9, 5.1, 0), (0.6, 0.6, 0.6), rings=5, segments=10)
    cylinder(dark, (1.9, 5.1, 0), (2.25, 3.75, -0.05), 0.3, segments=8)
    cylinder(body, (2.25, 3.75, -0.05), (2.35, 2.45, -0.25), 0.36, segments=8)
    block(dark, (2.38, 2.1, -0.3), (0.6, 0.7, 0.6), bevel=0.15)
    cylinder(dark, (-1.9, 5.1, 0), (-2.2, 3.9, -0.6), 0.3, segments=8)
    cylinder(body, (-2.2, 3.9, -0.6), (-1.3, 3.6, -1.6), 0.36, segments=8)
    block(dark, (-1.15, 3.65, -1.75), (0.6, 0.6, 0.6), bevel=0.15)
    block(board, (-0.75, 3.9, -2.05), (1.5, 2.0, 0.14), bevel=0.04, rot=rot_x(-20))
    block(paper, (-0.75, 3.85, -2.13), (1.25, 1.6, 0.06), rot=rot_x(-20))
    block(dark, (-0.75, 4.85, -2.3), (0.6, 0.2, 0.2), bevel=0.04)
    # Body-part pieces for the client NPC rig (custom robot skeleton: hips at the top of the leg
    # cylinders y 2.5, neck base y 5.6, shoulder balls at (+-1.9, 5.1); bone ends = the hands).
    bones = {
        "Torso": ((0.0, 2.5, 0.0), (0.0, 5.4, 0.0)),
        "Head": ((0.0, 5.6, 0.0), (0.0, 9.7, 0.0)),
        "ArmL": ((-1.9, 5.1, 0.0), (-1.15, 3.65, -1.75)),
        "ArmR": ((1.9, 5.1, 0.0), (2.38, 2.1, -0.3)),
        "LegL": ((-0.8, 2.5, 0.0), (-0.8, 0.0, 0.0)),
        "LegR": ((0.8, 2.5, 0.0), (0.8, 0.0, 0.0)),
    }
    rig_split(m, bones, assign={"Clipboard": "ArmL", "Paper": "ArmL"})
    return m


# ------------------------------------------------------------------------------------------------
# AA Tower base (A7_AATower)
# ------------------------------------------------------------------------------------------------

AA_PLINTH = 14.0  # square plinth side: fits B8f's largest level (AATower5 pad 12.16 x 12.16)
AA_MOUNT_Y = 1.0  # plinth top = where AATower1..5 stand (layout aaTowerMount)


def build_aa_tower():
    """
    The AA Tower feature's BASE only: a hazard-bordered 14 x 14 concrete plinth with four red
    beacon posts on its corners and a lettered "AA DEFENSE" placard in front. The tower itself is
    B8f's levelled AATower1..5 (attack mode swaps levels on top of this plinth at the layout's
    `aaTowerMount`, +Y up, barrels -Z at rest), so nothing here has to change when a level is bought.
    """
    m = Model("A7_AATower", "ground centre (deck top); AATower1..5 stand on the plinth top y = 1.0", budget=2500)
    plinth = m.piece("Plinth", CONCRETE_DARK)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    posts = m.piece("Posts", DARK_STEEL)
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    red = m.piece("Red", TOY_RED)
    sign = m.piece("Sign", CREAM)
    letters = m.piece("Letters", HAZARD_BLACK, material="Smooth")
    half = AA_PLINTH / 2
    block(plinth, (0, AA_MOUNT_Y / 2, 0), (AA_PLINTH, AA_MOUNT_Y, AA_PLINTH), bevel=0.2)
    _hazard_border(yellow, black, (0, 0), (AA_PLINTH - 0.4, AA_PLINTH - 0.4), 1.2, AA_MOUNT_Y, stripe=1.2)
    # Corner beacon posts sit outside the level-5 pad (half 6.08): centres at +-6.5, radius 0.28.
    for sx in (-1, 1):
        for sz in (-1, 1):
            x, z = sx * (half - 0.5), sz * (half - 0.5)
            cylinder(posts, (x, AA_MOUNT_Y, z), (x, AA_MOUNT_Y + 2.2, z), 0.28, segments=8)
            ellipsoid(beacon, (x, AA_MOUNT_Y + 2.45, z), (0.38, 0.42, 0.38), rings=4, segments=8)
    # Placard on two legs just in front of the plinth (the attack-mode prompt stands behind it).
    sign_c, sign_size = (0, 2.3, -half - 0.8), (7.2, 1.9)
    for sx in (-1, 1):
        block(posts, (sx * 2.6, 0.7, -half - 0.6), (0.3, 1.4, 0.3), bevel=0.05)
    sign_frame(red, sign, sign_c, sign_size, border=0.3, depth=0.35)
    sign_text(letters, "AA DEFENSE", sign_c, sign_size, 0.3, 0.35, letter_depth=0.15, pad=0.12)
    return m


# ------------------------------------------------------------------------------------------------
# Attack Console (A7_AttackConsole)
# ------------------------------------------------------------------------------------------------


def build_attack_console():
    """
    The Attack Console: hazard plinth, chunky desk with a red sloped control top, the BIG RED
    BUTTON under a flipped-open glass cover, two joysticks, glowing keys, a big tilted monitor
    (piece Screen: a target-map SurfaceGui may go on its -Z face, glowing map art in front) and a lettered
    "ATTACK!" sign on top. Operator stands at the -Z side (toward the road).
    """
    m = Model("A7_AttackConsole", "ground centre (deck top); operator side and screen face -Z", budget=3500)
    plinth = m.piece("Plinth", CONCRETE_DARK)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    desk = m.piece("Desk", DARK_STEEL)
    trim = m.piece("Trim", TOY_RED)
    button = m.piece("Button", TOY_RED, material="Neon")
    cover = m.piece("Cover", GLASS, material="Glass", transparency=0.45)
    sticks = m.piece("Sticks", CHARCOAL, material="StudsSmall")
    screen = m.piece("Screen", SCREEN_BLUE, material="Neon")
    mapart = m.piece("MapArt", GLOW_GREEN, material="Neon")
    sign = m.piece("Sign", CREAM)
    block(plinth, (0, 0.3, 0), (12.0, 0.6, 7.0), bevel=0.12)
    _hazard_border(yellow, black, (0, 0), (11.6, 6.6), 1.0, 0.6, stripe=0.9)
    # Desk body + sloped control top (rot_x tilts the top up toward +Z).
    block(desk, (0, 2.1, 0.2), (10.0, 3.0, 3.4), bevel=0.3)
    block(trim, (0, 3.75, 0.2), (10.4, 0.5, 3.8), bevel=0.15, rot=rot_x(-12))
    hazard_band(yellow, black, (0, 1.1, -1.55), (9.6, 0.9, 0.2), stripe=0.8)
    # Big red button: yellow collar, glowing dome, glass cover flipped open toward +Z.
    disc(yellow, (0, 3.9, -0.3), 1.0, 0.35, segments=16)
    ellipsoid(button, (0, 4.3, -0.3), (0.75, 0.45, 0.75), rings=5, segments=14)
    block(cover, (0, 5.0, 0.75), (1.9, 1.6, 0.12), rot=rot_x(-70))
    # Joysticks + glowing key rows.
    for s in (-1, 1):
        cylinder(sticks, (s * 3.3, 3.95, -0.2), (s * 3.3, 5.1, -0.2), 0.14, segments=8)
        ellipsoid(trim, (s * 3.3, 5.25, -0.2), (0.38, 0.38, 0.38), rings=5, segments=10)
        disc(sticks, (s * 3.3, 3.85, -0.2), 0.6, 0.2, segments=12)
        for i in range(3):
            block(mapart, (s * (1.6 + i * 0.55), 4.02, 0.6), (0.38, 0.12, 0.38), bevel=0.04)
    # Monitor: dark frame, glowing screen (tilted back 10 deg), map art just in front of it.
    # Screen-plane basis: centre C, up U = rot_x(10)*(0,1,0), outward normal N = rot_x(10)*(0,0,-1).
    tilt = rot_x(10)
    c10, s10 = math.cos(math.radians(10)), math.sin(math.radians(10))
    centre = Vector((0.0, 7.45, 1.15))
    up_v = Vector((0.0, c10, s10))
    out_v = Vector((0.0, s10, -c10))

    def on_screen(x, y, out):
        """Point x right / y up on the screen face, `out` studs in front of the glowing surface."""
        p = centre + Vector((x, 0.0, 0.0)) + up_v * y + out_v * (0.06 + out)
        return (p.x, p.y, p.z)

    block(desk, (0, 7.4, 1.5), (9.4, 5.6, 0.6), bevel=0.25, rot=tilt)
    box(screen, tuple(centre), (8.6, 4.8, 0.12), rot=tilt)
    for gx in (-3.0, -1.0, 1.0, 3.0):
        box(mapart, on_screen(gx, 0.0, 0.02), (0.08, 4.4, 0.04), rot=tilt)
    for gy in (-1.2, 0.0, 1.2):
        box(mapart, on_screen(0.0, gy, 0.02), (8.2, 0.08, 0.04), rot=tilt)
    for a in range(12):  # target reticle ring (12 short segments) on the right half
        a0, a1 = 2 * math.pi * a / 12, 2 * math.pi * (a + 1) / 12
        # out = 0.2: the ring (0.12 .. 0.28 in front) never shares a plane with the grid (0 .. 0.04).
        p0 = on_screen(2.0 + 1.1 * math.cos(a0), 0.15 + 1.1 * math.sin(a0), 0.2)
        p1 = on_screen(2.0 + 1.1 * math.cos(a1), 0.15 + 1.1 * math.sin(a1), 0.2)
        bar(button, p0, p1, 0.16)
    cylinder(desk, (0, 3.6, 1.8), (0, 4.8, 1.8), 0.5, segments=10)  # monitor stand
    letters = m.piece("Letters", HAZARD_BLACK, material="Smooth")
    sign_c, sign_size = (0, 11.25, 1.95), (7.4, 2.2)  # rests on the monitor top
    sign_frame(trim, sign, sign_c, sign_size, border=0.3, depth=0.4)
    sign_text(letters, "ATTACK!", sign_c, sign_size, 0.3, 0.4, letter_depth=0.18, pad=0.15)
    return m


BUILDERS = {
    "A7_Deck": build_deck,
    "A7_EntryArch": build_entry_arch,
    "A7_SiloBase": build_silo_base,
    "A7_SiloNuke_Red": build_silo_nuke_red,
    "A7_SiloNuke_Mint": build_silo_nuke_mint,
    "A7_SiloNuke_Gold": build_silo_nuke_gold,
    "A7_RadarDish": build_radar_dish,
    "A7_ControlRoom": build_control_room,
    "A7_HazardFloor": build_hazard_floor,
    "A7_LaunchDirector": build_launch_director,
    "A7_AATower": build_aa_tower,
    "A7_AttackConsole": build_attack_console,
}
