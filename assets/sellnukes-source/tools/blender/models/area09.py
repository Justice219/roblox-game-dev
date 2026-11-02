"""
area09.py — Area 9 "Space Port" (spec §3.9): a candy-coloured toy launch complex. A big cartoon
orbital rocket stands on a round launch platform beside a red-and-white gantry tower; around it
grow mission control, fuel tanks, a booster-rocket rack, a turning satellite dish, an astronaut
crew and a space-elevator column that climbs to the height budget. Every pad purchase is its own
model set so each one builds in separately; placement lives in
src/shared/Config/AreaLayouts/Area09.luau (slot-local frame, docs/areas-art.md "Area 9").

Also hosts small SHARED space/industry helpers imported by area10.py:
    disc_z(piece, center, radius, depth)       round plate facing -Z / +Z (badges, portholes)
    band(piece, cx, cz, radius, y0, y1)        raised ring hugging an upright cylinder
    star(piece, center, r_out, depth)          5-point star facing -Z (decor)
    cable(piece, a, b, sag, thick)             sagging cable as a chain of bars (power lines)
    astronaut(pieces, xf, accent)              toy astronaut (same proportions as area04.toy_figure)
    headset(dark, xf)                          ear cups + mic for a toy_figure head
    text_both(piece, lines, cy, z_front, z_back, cell, depth)   block letters reading correctly on
                                               BOTH faces of a sign (owner R17)
    text_arch(key, lines, ...)                 double-sided entry arch (area01 entry_arch look)

Every model has its OWN pivot (ground centre unless stated, front = -Z, i.e. toward the road when
placed with an identity rotation). Models that stand on the area floor are placed at y = LOT_TOP
(0.5, shared with areas 1-3: the floor is a 0.5-stud plate).

Models (key: pivot / notes)                                             build key
    A9_Floor            SLOT ORIGIN pivot (layout cf = identity); top y = 0.5   base
    A9_EntryArch        ground centre between the posts; "SPACE PORT" letters   base
    A9_LaunchPlatform   PRODUCER base: round pad, deck top y = 3, steps at -Z   A9_LaunchPad
    A9_Rocket           PRODUCER hero: base centre on the deck; whole model     A9_LaunchPad
                        is the liftable launch FX anchor (EngineGlow = flame)
    A9_LaunchTower      gantry beside the rocket (platform-local (9, 3, 0))      A9_LaunchPad
    A9_FuelTanks        sphere + upright + capsule tanks, pipes, fuel sign      A9_FuelTanks
    A9_MissionControl   glass-front control building, screen wall, roof dome    A9_MissionControl
    A9_BoosterRockets   three boosters clamped in a steel rack                   A9_BoosterRockets
    A9_SatelliteDish    big dish on a block base; Dish turns about pivot Y      A9_SatelliteDish
    A9_AstronautCrew    four astronauts on a crew stage with a flag             A9_AstronautCrew
    A9_SpaceElevator    station + column to y ~ 78; Climber slides along Y      A9_SpaceElevator
    A9_FlightDirector   Manager: director with headset + clipboard at console   A9_FlightDirector

Animation / FX contract — full table in docs/areas-art.md "Area 9". Piece names follow
src/shared/Config/WorldFxConfig (B4's WorldFxController animates by name, about each piece's OWN
bbox centre):
    A9_SatelliteDish.Dish     "Dish": oscillates about Y; its bbox centre lies on the pivot's
                              vertical axis, so the dish swings on its column.
    A9_BoosterRockets.Lamps   alias "Bulb": warm light over the rack.
    A9_Rocket (whole model)   NOT a WorldFx piece: the launch lift is a model-level effect (move the
                              model along +Y, then reset); EngineGlow = flame/particle anchor.
    A9_SpaceElevator.Climber  no WorldFx row yet; a `Climber = bob, amplitude 14, period 12` row
                              would ride it between y = 8 and y = 36 (rest y = 22).
    *.Lights, *.Beacon, *.Screens, EngineGlow, Ribbon    static Neon (no row).

Budgets (docs/world-art.md §4): floor/arch <= 6,000 (arch carries geometry letters), machines and
figure groups <= 3,000-4,000, hero landmarks (rocket, tower, elevator, mission control) <= 6,000.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import (
    CHARCOAL,
    CONCRETE,
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
    ORANGE,
    SIDEWALK,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    WHITE,
    YELLOW,
)
from snkit.kit import block, disc, hazard_band, hazard_ring, ladder, nuke_body, pipe, tank, trefoil, truss
from snkit.shapes import add_faces, bar, box, cylinder, ellipsoid, prism, revolve, ring_tube, rot_x, rot_z

from models.area01 import FONT_ROWS, LOT_TOP, SKIN, SLOT_PIVOT, block_text, lot_stripes, text_cells
from models.area04 import Xf, toy_figure

# ------------------------------------------------------------------------------------------------
# Area-local palette (space-port candy colours; the global palette lives in snkit/core.py)
# ------------------------------------------------------------------------------------------------

SPACE_NAVY = (44, 58, 126)  # walkway, crew stage, arch posts
CYAN_GLOW = (96, 232, 255)  # runway / platform lights, elevator ribbon (Neon)
GOLD = (255, 192, 48)  # astronaut visors
CONCRETE_LIGHT = (198, 200, 210)  # second paving tone next to snkit CONCRETE
HAIR_BROWN = (110, 70, 44)

SLOT_W = 104.0
SLOT_D = 70.0

# ------------------------------------------------------------------------------------------------
# Shared helpers (also imported by area10.py)
# ------------------------------------------------------------------------------------------------


def disc_z(piece, center, radius, depth, segments=16):
    """
    Round plate whose faces point along Z (badges, portholes, emblems), centred on `center`,
    `depth` thick along Z. Chamfer-free so it reads as a crisp toy decal.

    Example: disc_z(m.piece("Badge", HAZARD_YELLOW), (0, 10, -3.3), 1.5, 0.6)
    """
    revolve(
        piece,
        [(0.0, -depth / 2), (radius, -depth / 2), (radius, depth / 2), (0.0, depth / 2)],
        center=center,
        segments=segments,
        rot=rot_x(90),
    )


def band(piece, cx, cz, radius, y0, y1, out=0.14, segments=20):
    """
    Raised square-section ring hugging an upright cylinder of `radius` between heights y0..y1
    (tank bands, rocket stripes). The inner lip sits 0.1 inside the wall so no gap ever shows.
    """
    revolve(
        piece,
        [(radius - 0.1, y0), (radius + out, y0), (radius + out, y1), (radius - 0.1, y1)],
        center=(cx, 0.0, cz),
        segments=segments,
        closed=True,
    )


def star(piece, center, r_out, depth, r_in_ratio=0.45, normal_z=True):
    """
    Chunky 5-point star facing -Z (normal_z) or lying flat facing +Y (normal_z=False), centred on
    `center`, one point up / toward -Z. Concave outline; Blender's triangulator handles it.
    """
    cx, cy, cz = center
    pts = []
    for k in range(10):
        a = math.pi / 2 + k * math.pi / 5
        r = r_out if k % 2 == 0 else r_out * r_in_ratio
        if normal_z:
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a), cz))
        else:
            pts.append((cx + r * math.cos(a), cy, cz - r * math.sin(a)))
    prism(piece, pts, (0, 0, 1) if normal_z else (0, 1, 0), depth)


def cable(piece, a, b, sag, thick=0.22, steps=8):
    """
    Power cable from a to b sagging `sag` studs at mid-span (parabola), as `steps` straight bars
    plus tiny knuckles so the joints never show gaps.
    """
    a, b = Vector(a), Vector(b)
    pts = []
    for i in range(steps + 1):
        t = i / steps
        p = a.lerp(b, t)
        p.y -= sag * 4 * t * (1 - t)
        pts.append(p)
    for p, q in zip(pts, pts[1:]):
        bar(piece, (p.x, p.y, p.z), (q.x, q.y, q.z), thick)


def astronaut(pc, xf, accent, wave=False, wave_pieces=None):
    """
    Original toy astronaut (~6.6 studs tall incl. helmet), feet at xf's base, facing local -Z.
    Same body proportions as area04.toy_figure so crews and managers line up across areas.

    pc: {"suit", "boots" (boots + gloves), "visor", "pack", "shine"}; accent = this astronaut's
    colour piece (chest box, belt, arm stripes, neck ring) so one model can hold a whole crew with
    different accent colours at one draw call per colour.
    wave: raise the left arm in a wave.
    wave_pieces: optional {"suit", "accent", "glove"} pieces for the raised waving arm only, so the
    arm can move on its own (owner R75: WorldFx swings it about the shoulder hinge).
    NOTE: ellipsoids (helmet/visor) are not yawed, so crews must use yaw multiples of 180.
    """
    suit, boots, visor, pack, shine = pc["suit"], pc["boots"], pc["visor"], pc["pack"], pc["shine"]
    rot = xf.rot
    for s in (-1, 1):
        block(boots, xf.p(s * 0.52, 0.32, -0.1), (1.0, 0.64, 1.36), bevel=0.16, rot=rot)
        block(suit, xf.p(s * 0.52, 1.5, 0), (0.96, 1.76, 1.0), bevel=0.16, rot=rot)
    block(suit, xf.p(0, 2.5, 0), (2.2, 0.52, 1.1), bevel=0.14, rot=rot)  # hips
    block(suit, xf.p(0, 3.55, 0), (2.3, 1.9, 1.2), bevel=0.26, rot=rot)  # torso 2.6..4.5
    block(accent, xf.p(0, 3.6, -0.66), (1.1, 0.78, 0.2), bevel=0.06, rot=rot)  # chest control box
    block(accent, xf.p(0, 2.62, 0), (2.28, 0.24, 1.16), bevel=0.05, rot=rot)  # belt
    for s in (-1, 1):
        if wave and s < 0:
            # Raised waving arm: block tilted out and up from the shoulder.
            arm_rot = xf.r(rot_z(-150))
            sh = Vector((s * 1.5, 4.25, 0))
            d = Vector((s * math.sin(math.radians(150)), -math.cos(math.radians(150)), 0.0))
            mid = sh + d * 0.9
            wp = wave_pieces or {}
            block(wp.get("suit", suit), xf.p(mid.x, mid.y, mid.z), (0.8, 1.8, 0.86), bevel=0.2, rot=arm_rot)
            stripe = sh + d * 0.45
            block(wp.get("accent", accent), xf.p(stripe.x, stripe.y, stripe.z), (0.86, 0.24, 0.92), bevel=0.05, rot=arm_rot)
            hand = sh + d * 1.95
            block(wp.get("glove", boots), xf.p(hand.x, hand.y, hand.z), (0.72, 0.56, 0.74), bevel=0.14, rot=arm_rot)
            continue
        block(suit, xf.p(s * 1.5, 3.5, 0), (0.8, 1.8, 0.86), bevel=0.2, rot=rot)  # 2.6..4.4
        block(accent, xf.p(s * 1.5, 4.05, 0), (0.86, 0.24, 0.92), bevel=0.05, rot=rot)
        block(boots, xf.p(s * 1.5, 2.42, 0), (0.72, 0.56, 0.74), bevel=0.14, rot=rot)  # glove
    # Life-support backpack with two little tanks on its back.
    block(pack, xf.p(0, 3.65, 0.95), (1.9, 2.1, 0.76), bevel=0.2, rot=rot)
    for s in (-1, 1):
        cylinder(pack, xf.p(s * 0.5, 2.85, 1.42), xf.p(s * 0.5, 4.45, 1.42), 0.3, segments=8)
    # Neck ring, round helmet, gold visor with a white shine stroke.
    revolve(accent, [(0.0, -0.14), (0.98, -0.14), (0.98, 0.14), (0.0, 0.14)], center=xf.p(0, 4.62, 0), segments=14)
    ellipsoid(suit, xf.p(0, 5.5, 0), (1.18, 1.12, 1.12), rings=8, segments=14)
    ellipsoid(visor, xf.p(0, 5.55, -0.62), (0.9, 0.68, 0.6), rings=6, segments=12)
    block(shine, xf.p(-0.36, 5.86, -1.16), (0.3, 0.14, 0.08), bevel=0.03, rot=xf.r(rot_z(25)))
    block(shine, xf.p(-0.12, 5.98, -1.12), (0.12, 0.1, 0.08), bevel=0.02, rot=rot)


def headset(dark, xf):
    """Ear cups, head band and a boom mic for an area04.toy_figure head (head axis at local x=0)."""
    for s in (-1, 1):
        cylinder(dark, xf.p(s * 0.7, 5.2, 0.0), xf.p(s * 0.92, 5.2, 0.0), 0.34, segments=10)
        bar(dark, xf.p(s * 0.82, 5.45, 0.0), xf.p(s * 0.82, 6.0, 0.0), 0.16)
    bar(dark, xf.p(-0.82, 6.0, 0.0), xf.p(0.82, 6.0, 0.0), 0.16)
    bar(dark, xf.p(-0.86, 5.0, -0.1), xf.p(-0.45, 4.92, -0.82), 0.1)
    ellipsoid(dark, xf.p(-0.38, 4.92, -0.86), (0.13, 0.13, 0.13), rings=4, segments=6)


def text_both(piece, lines, cy, z_front, z_back, cell, depth):
    """
    Block letters on BOTH faces of a sign board centred on x = 0 (owner R17: signs must read
    correctly from the road AND from inside the area).

    Front: area01.block_text facing -Z with its letters' back on `z_front` (the road side; text
    advances toward -X, the road viewer's right). Back: the same text built at z = -z_back, then
    rotated 180 deg about the vertical axis (Roblox (x, z) -> (-x, -z); Blender (x, y) -> (-x, -y)),
    so it sits on the +Z face at `z_back`, extrudes toward +Z and reads left-to-right for a viewer
    inside the area. A rotation (not a mirror) keeps glyph shapes and face winding correct.

    Example: text_both(m.piece("Letters", WHITE, "Smooth"), "SPACE PORT", 14.0, -0.48, 0.48, 0.44, 0.4)
    """
    block_text(piece, lines, (0.0, cy, z_front), cell, depth)
    before = set(piece.bm.verts)
    block_text(piece, lines, (0.0, cy, -z_back), cell, depth)
    for v in piece.bm.verts:
        if v not in before:
            v.co.x = -v.co.x
            v.co.y = -v.co.y


def text_arch(
    key,
    lines,
    *,
    inner=20.0,
    post_h=9.0,
    post_w=3.0,
    post_color=SPACE_NAVY,
    trim_color=WHITE,
    panel_color=DEEP_BLUE,
    letter_color=WHITE,
    finial_colors=(ORANGE, SKY_BLUE),
    budget=6000,
):
    """
    Double-sided themed entry arch (owner R17). Same look and proportions as area01.entry_arch —
    two chunky posts on plinths with hazard bands, a framed sign board, pocket-nuke finials and
    marquee bulbs — but the block letters are on BOTH faces (text_both) and the bulbs line both
    faces. Lean (R11): crisp 12-triangle letter cells, 16-triangle bulbs.

    inner: clear walkway width between the posts. Pivot: ground centre under the board, front -Z.
    Returns the Model with `arch_info` (board_y, board_h, board_w, post_x, post_w, top_y, depth) so
    callers can add themed toppers.
    """
    m = Model(key, "ground centre between the posts; sign reads correctly from -Z (road) and +Z (area)", budget=budget)
    posts = m.piece("Posts", post_color)
    trim = m.piece("Trim", trim_color)
    panel = m.piece("Panel", panel_color)
    letters = m.piece("Letters", letter_color, material="Smooth")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    px = inner / 2 + post_w / 2
    for sx in (-1, 1):
        x = sx * px
        block(trim, (x, 0.5, 0), (post_w + 1.0, 1.0, post_w + 1.0), bevel=0.2)
        block(posts, (x, 1.0 + post_h / 2, 0), (post_w, post_h, post_w), bevel=0.25)
        for zs in (-1, 1):
            hazard_band(yellow, black, (x, 2.0, zs * (post_w / 2 + 0.06)), (post_w - 0.3, 1.2, 0.18), stripe=0.55)
    lines = [lines] if isinstance(lines, str) else list(lines)
    board_w = inner + 2 * post_w + 2.0
    pad = 1.0
    cell = min(0.62, (board_w - 2 * pad - 0.6) / max(text_cells(line) for line in lines))
    rows = len(lines) * FONT_ROWS + (len(lines) - 1) * 2
    board_h = rows * cell + 2 * pad
    board_y = 1.0 + post_h + board_h / 2 - 0.4
    depth = 1.2
    block(panel, (0, board_y, 0), (board_w - 0.6, board_h - 0.6, depth * 0.8), bevel=0.15)
    frame_t = 0.55
    for sy in (-1, 1):
        block(trim, (0, board_y + sy * (board_h / 2 - frame_t / 2), 0), (board_w, frame_t, depth), bevel=0.15)
    for sx in (-1, 1):
        block(trim, (sx * (board_w / 2 - frame_t / 2), board_y, 0), (frame_t, board_h, depth), bevel=0.15)
    text_both(letters, lines, board_y, -depth * 0.4, depth * 0.4, cell, 0.4)
    top_y = 1.0 + post_h + board_h - 0.4
    nose = m.piece("FinialNose", WHITE, material="StudsSmall")
    fins = m.piece("FinialFins", CHARCOAL, material="StudsSmall")
    core = m.piece("FinialCore", GLOW_GREEN, material="Neon")
    for sx, colour in zip((-1, 1), finial_colors):
        x = sx * px
        block(trim, (x, top_y + 0.35, 0), (post_w + 0.6, 0.7, post_w + 0.6), bevel=0.2)
        body = m.piece(f"Finial{'L' if sx < 0 else 'R'}", colour, material="StudsSmall")
        nuke_body(body, nose, fins, core, base=(x, top_y + 0.7, 0), length=4.2, radius=1.0, segments=12)
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    count = max(6, int(board_w / 2.2))
    for i in range(count):
        x = -board_w / 2 + 1.0 + (board_w - 2.0) * i / (count - 1)
        for sy in (-1, 1):
            for sz in (-1, 1):
                ellipsoid(bulbs, (x, board_y + sy * (board_h / 2 - frame_t / 2), sz * (depth / 2 + 0.12)), (0.2, 0.2, 0.2), rings=3, segments=4)
    m.arch_info = {
        "board_y": board_y,
        "board_h": board_h,
        "board_w": board_w,
        "post_x": px,
        "post_w": post_w,
        "top_y": top_y,
        "depth": depth,
    }
    return m


# ------------------------------------------------------------------------------------------------
# Base: floor + entry arch
# ------------------------------------------------------------------------------------------------


def build_floor():
    """
    Launch-complex ground (slot-origin pivot): two-tone concrete plates, a navy walkway with white
    edge lines and cyan runway lights from the arch to the launch platform steps, a dark apron
    disc with a hazard ring where the platform stands (slot (0, 36)), and a low curb on the sides
    and back.
    """
    m = Model("A9_Floor", SLOT_PIVOT, budget=4000)
    slab = m.piece("Slab", CONCRETE)
    slab2 = m.piece("SlabLight", CONCRETE_LIGHT)
    apron = m.piece("Apron", CONCRETE_DARK)
    path = m.piece("Path", SPACE_NAVY)
    lines = m.piece("Lines", WHITE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    lights = m.piece("Lights", CYAN_GLOW, material="Neon")
    curb = m.piece("Curb", SIDEWALK)
    t = LOT_TOP
    lot_stripes(slab, slab2, -SLOT_W / 2, SLOT_W / 2, 0.0, SLOT_D, stripe=8.0, top=t, along="z")
    # Walkway: road edge -> the apron hazard ring (outer edge z = 18 at x = 0; the platform steps
    # start just beyond it). Paint stops at the ring so no line shares its top plane (owner R18).
    walk_end = 18.0
    block(path, (0, t + 0.04, walk_end / 2), (10.0, 0.08, walk_end), bevel=0.03)
    for sx in (-1, 1):
        block(lines, (sx * 5.25, t + 0.05, walk_end / 2), (0.5, 0.1, walk_end), bevel=0.03)
    for i in range(4):
        block(lines, (0, t + 0.05, 2.5 + i * 4.0), (0.4, 0.1, 2.0), bevel=0.03)
    for i in range(5):
        for sx in (-1, 1):
            block(lights, (sx * 6.0, t + 0.12, 1.5 + i * 3.8), (0.6, 0.24, 0.6), bevel=0.08)
    # Launch apron + hazard ring around the platform.
    disc(apron, (0, t, 36.0), 16.5, 0.07, segments=40, bevel=0.03)
    hazard_ring(yellow, black, (0, 0, 36.0), 16.5, 18.0, t, t + 0.1, count=36)
    # Yellow guide lines between the pad strip and the build zone (both sides of the walkway).
    guide = m.piece("Guide", YELLOW)
    for sx in (-1, 1):
        block(guide, (sx * 28.5, t + 0.05, 18.6), (44.0, 0.1, 0.5), bevel=0.03)
    # Curb on the two sides and the back (walkable 0.4 lip).
    block(curb, (0, t + 0.2, SLOT_D - 0.5), (SLOT_W, 0.4, 1.0), bevel=0.12)
    for sx in (-1, 1):
        block(curb, (sx * (SLOT_W / 2 - 0.5), t + 0.2, SLOT_D / 2 + 1.0), (1.0, 0.4, SLOT_D - 2.0), bevel=0.12)
    return m


def build_entry_arch():
    """
    "SPACE PORT" entry arch: double-sided text_arch (letters read correctly from the road AND from
    inside the area, owner R17) in navy / white / deep blue, plus a ringed orange planet on top and
    yellow stars on both faces of the posts.
    """
    m = text_arch(
        "A9_EntryArch",
        "SPACE PORT",
        inner=20.0,
        post_color=SPACE_NAVY,
        trim_color=WHITE,
        panel_color=DEEP_BLUE,
        letter_color=WHITE,
        finial_colors=(ORANGE, SKY_BLUE),
    )
    info = m.arch_info
    planet = m.piece("Planet", ORANGE)
    ring = m.piece("PlanetRing", YELLOW)
    stars = m.piece("Stars", YELLOW, material="Smooth")
    trim = m.piece("Trim", WHITE)
    top = info["top_y"]
    # Little stand + planet + tilted ring above the board centre.
    block(trim, (0, top + 0.5, 0), (2.4, 1.0, 1.6), bevel=0.2)
    ellipsoid(planet, (0, top + 3.0, 0), (2.0, 2.0, 2.0), rings=10, segments=16)
    revolve(ring, [(2.5, -0.16), (3.6, -0.1), (3.6, 0.1), (2.5, 0.16)], center=(0, top + 3.0, 0), segments=24, closed=True, rot=rot_x(14) @ rot_z(18))
    # Stars on the post fronts and either side of the planet.
    face = info["post_w"] / 2 + 0.08
    for sx in (-1, 1):
        for sz in (-1, 1):
            star(stars, (sx * info["post_x"], 7.4, sz * face), 0.9, 0.16)
        star(stars, (sx * 5.0, top + 1.7, 0), 0.8, 0.3)
    return m


# ------------------------------------------------------------------------------------------------
# Producer: launch platform + rocket + tower (build key A9_LaunchPad)
# ------------------------------------------------------------------------------------------------

DECK_R = 12.0
DECK_TOP = 3.0
ROCKET_R = 3.3


# Half-depth (|z|) of the gantry foot on the launch deck: A9_LaunchTower's 6.4-wide base plate
# plus its hazard bands (z +-3.22, 0.12 thick), + 0.05 clearance.
TOWER_FOOT_HALF_Z = 3.33


def _arc_tube(piece, center, radius, width, depth, a0, a1, segments=24):
    """
    Open square-section arc lying flat (ring_tube's profile) from angle a0 to a1 (radians, Roblox
    x = cos, z = sin), with flat end caps. Used where a ring must stop at something standing on it.

    Example: _arc_tube(pipes, (0, 3.3, 0), 8.8, 0.45, 0.45, 0.39, 5.9)
    """
    corners = [(-width / 2, -depth / 2), (width / 2, -depth / 2), (width / 2, depth / 2), (-width / 2, depth / 2)]
    points = []
    for s in range(segments + 1):
        t = a0 + (a1 - a0) * s / segments
        for dr, dy in corners:
            r = radius + dr
            points.append((center[0] + r * math.cos(t), center[1] + dy, center[2] + r * math.sin(t)))
    faces = []
    for s in range(segments):
        a, b = s * 4, (s + 1) * 4
        for k in range(4):
            k2 = (k + 1) % 4
            faces.append((a + k, a + k2, b + k2, b + k))
    faces.append((3, 2, 1, 0))
    last = segments * 4
    faces.append((last, last + 1, last + 2, last + 3))
    add_faces(piece, points, faces)


def build_launch_platform():
    """
    Round launch platform: concrete deck (r = 12, top y = 3) with a hazard rim ring, a dark flame
    trench under the rocket, a deluge-pipe ring, four red hold-down clamps, steel buttresses with
    cyan rim lights, and three steps on the front (-Z) so players can walk up to the rocket.
    """
    m = Model(
        "A9_LaunchPlatform",
        "ground centre of the pad (layout: slot (0, 0.5, 36)); deck top y = 3; rocket at (0, 3, 0); steps at -Z",
        budget=4000,
    )
    deck = m.piece("Deck", CONCRETE)
    steel = m.piece("Steel", DARK_STEEL)
    pipes = m.piece("Pipes", STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    trench = m.piece("Trench", CHARCOAL)
    clamps = m.piece("Clamps", TOY_RED)
    lights = m.piece("Lights", CYAN_GLOW, material="Neon")
    steps = m.piece("Steps", CONCRETE_DARK)
    revolve(deck, [(0.0, 0.0), (DECK_R, 0.0), (DECK_R, DECK_TOP - 0.45), (DECK_R - 0.45, DECK_TOP), (0.0, DECK_TOP)], segments=32)
    hazard_ring(yellow, black, (0, 0, 0), 10.0, 11.4, DECK_TOP, DECK_TOP + 0.12, count=28)
    # Flame trench: dark square plate under the rocket + two exhaust slots to the sides.
    block(trench, (0, DECK_TOP + 0.05, 0), (7.6, 0.1, 7.6), bevel=0.04)
    for sx in (-1, 1):
        block(trench, (sx * 6.2, DECK_TOP + 0.05, 0), (4.6, 0.1, 3.0), bevel=0.04)
    # Buttresses + rim lights around the side (skipping the step zone at -Z).
    for k in range(12):
        a = math.pi / 12 + k * math.pi / 6
        dx, dz = math.cos(a), math.sin(a)
        if dz < -0.5 and abs(dx * DECK_R) < 6.0:
            continue
        bar(steel, (dx * 11.5, 1.3, dz * 11.5), (dx * 12.45, 1.3, dz * 12.45), 1.5)
        la = a + math.pi / 12
        lx, lz = math.cos(la), math.sin(la)
        if not (lz < -0.5 and abs(lx * DECK_R) < 6.0):
            block(lights, (lx * 11.95, 1.9, lz * 11.95), (0.6, 0.6, 0.6), bevel=0.1)
    # Deluge pipe ring with inward nozzles. The ring stops at the gantry's base plate (A9_LaunchTower
    # stands at platform-local x 9 on a 6.4-wide plate, hazard bands out to |z| 3.28): it runs INTO
    # the tower foot instead of through it (owner R24, check_area_overlaps.py).
    tower_gap = math.asin(TOWER_FOOT_HALF_Z / 8.8)
    _arc_tube(pipes, (0, DECK_TOP + 0.3, 0), 8.8, 0.45, 0.45, tower_gap, 2 * math.pi - tower_gap, segments=30)
    for k in range(8):
        a = k * math.pi / 4 + math.pi / 8
        if a < tower_gap + 0.1 or a > 2 * math.pi - tower_gap - 0.1:
            continue  # this nozzle would sit under the tower plate
        dx, dz = math.cos(a), math.sin(a)
        cylinder(pipes, (dx * 8.8, DECK_TOP + 0.3, dz * 8.8), (dx * 7.9, DECK_TOP + 0.55, dz * 7.9), 0.18, segments=6)
    # Hold-down clamps at 0/90/180/270 deg (rocket fins sit on the diagonals).
    for a in (0.0, math.pi / 2, math.pi, 1.5 * math.pi):
        dx, dz = math.cos(a), math.sin(a)
        bar(clamps, (dx * ROCKET_R * 1.02, DECK_TOP + 0.75, dz * ROCKET_R * 1.02), (dx * 5.9, DECK_TOP + 0.75, dz * 5.9), 1.1)
        if a == 0.0:
            continue  # +X: the gantry's base plate (x 5.8..12.2) is this clamp's anchor block
        # 1.4 tall (top y 4.4): never flush with the clamp bar (top 4.3) (owner R18).
        block(steel, (dx * 6.2, DECK_TOP + 0.7, dz * 6.2), (1.4, 1.4, 1.4), bevel=0.15)
    # Front steps (tops 0.05 under each level so the top step never z-fights the deck).
    for k, top in enumerate((0.95, 1.95, 2.95)):
        z_front = -(10.9 + (3 - k) * 1.25)
        z_back = -10.4
        block(steps, (0, top / 2, (z_front + z_back) / 2), (9.0, top, z_back - z_front), bevel=0.1)
        block(yellow, (0, top + 0.03, z_front + 0.35), (9.0, 0.08, 0.55), bevel=0.03)
    return m


def build_rocket():
    """
    The orbital rocket (~34 studs): white body, red nose + fins + stripe, deep-blue band, two
    portholes on the front, a yellow trefoil company badge, engine bells with an orange glow.
    Whole model = liftable launch anchor; EngineGlow is the flame/particle anchor (bottom).
    """
    m = Model(
        "A9_Rocket",
        "base centre (fin bottoms) on the platform deck: platform-local (0, 3, 0); nose up; badge faces -Z; "
        "whole model lifts for the launch FX; EngineGlow = flame anchor",
        budget=6000,
    )
    body = m.piece("Body", WHITE)
    red = m.piece("Red", TOY_RED)
    blue = m.piece("Blue", DEEP_BLUE)
    engines = m.piece("Engines", DARK_STEEL)
    glow = m.piece("EngineGlow", ORANGE, material="Neon")
    window = m.piece("Window", GLASS, material="Smooth")
    trim = m.piece("Trim", STEEL, material="StudsSmall")
    badge = m.piece("Badge", HAZARD_YELLOW, material="StudsSmall")
    mark = m.piece("Trefoil", HAZARD_BLACK, material="Smooth")
    r = ROCKET_R
    revolve(body, [(0.0, 2.3), (2.5, 2.3), (3.0, 2.8), (r, 4.0), (r, 22.6), (0.0, 22.6)], segments=24)
    revolve(
        red,
        [(0.0, 22.5), (r + 0.06, 22.5), (r, 24.4), (2.85, 27.2), (2.15, 30.0), (1.25, 32.2), (0.55, 33.4), (0.0, 33.7)],
        segments=24,
    )
    ellipsoid(trim, (0, 33.75, 0), (0.42, 0.42, 0.42), rings=5, segments=10)
    band(red, 0, 0, r, 19.2, 20.1, out=0.16, segments=24)
    band(blue, 0, 0, r, 5.6, 7.0, out=0.16, segments=24)
    band(blue, 0, 0, r, 21.3, 21.8, out=0.12, segments=24)
    # Four chunky fins on the diagonals (clamps + tower arms use the axes).
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        dx, dz = math.cos(a), math.sin(a)
        outline = [(2.8, 9.6), (6.3, 3.6), (6.3, 0.0), (2.8, 2.4)]
        pts = [(dx * rr, y, dz * rr) for rr, y in outline]
        prism(red, pts, (-dz, 0, dx), 0.9)
    # Engine bells: one big central bell + four small ones on the axes, orange glow discs below.
    revolve(engines, [(0.0, 2.4), (1.05, 2.4), (1.35, 1.5), (1.85, 0.35), (1.7, 0.25), (0.0, 0.25)], segments=16)
    disc(glow, (0, 0.12, 0), 1.45, 0.14, segments=16, bevel=0.03)
    for a in (0.0, math.pi / 2, math.pi, 1.5 * math.pi):
        bx, bz = 2.25 * math.cos(a), 2.25 * math.sin(a)
        revolve(engines, [(0.0, 2.4), (0.55, 2.4), (0.7, 1.4), (0.92, 0.45), (0.0, 0.45)], center=(bx, 0, bz), segments=10)
        disc(glow, (bx, 0.32, bz), 0.72, 0.14, segments=10, bevel=0.03)
    # Portholes (glass + steel rim) and white shine strokes on the front.
    for y, pr in ((17.4, 1.35), (13.9, 0.95)):
        disc_z(window, (0, y, -(r - 0.25)), pr, 0.7, segments=18)
        revolve(trim, [(pr, -0.2), (pr + 0.38, -0.2), (pr + 0.38, 0.2), (pr, 0.2)], center=(0, y, -(r + 0.05)), segments=18, closed=True, rot=rot_x(90))
        block(body, (-pr * 0.35, y + pr * 0.4, -(r + 0.12)), (pr * 0.55, 0.16, 0.1), bevel=0.03, rot=rot_z(30))
    # Company badge: yellow disc + black trefoil below the portholes.
    disc_z(badge, (0, 10.0, -(r - 0.25)), 1.55, 0.8, segments=18)
    trefoil(mark, (0, 10.0, -(r + 0.2)), 1.15, 0.1, normal=(0, 0, -1))
    return m


def build_launch_tower():
    """
    Red lattice gantry (44 studs) with white decks, a yellow elevator cab inside, three service
    arms toward the rocket (-X) incl. a white crew-access room, a mast and a red Neon beacon.
    """
    m = Model(
        "A9_LaunchTower",
        "ground centre of the tower foot (layout: platform-local (9, 3, 0)); arms reach toward -X; "
        "Beacon = blinking anchor",
        budget=6000,
    )
    tr = m.piece("Truss", TOY_RED)
    frame = m.piece("Frame", WHITE)
    arms = m.piece("Arms", DARK_STEEL)
    cab = m.piece("Cab", YELLOW)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.35)
    mast = m.piece("Mast", STEEL, material="StudsSmall")
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    h = 44.0
    w = 5.0
    block(frame, (0, 0.5, 0), (6.4, 1.0, 6.4), bevel=0.2)
    for zs in (-1, 1):
        hazard_band(yellow, black, (0, 0.5, zs * 3.22), (6.0, 0.8, 0.12), stripe=0.6)
    truss(tr, (0, 1.0, 0), (0, h, 0), w, member=0.5, bays=11)
    for y in (9.0, 17.0, 25.0, 33.0, 41.0):
        block(frame, (0, y, 0), (w + 0.9, 0.5, w + 0.9), bevel=0.12)
    block(frame, (0, h + 0.4, 0), (w + 1.6, 0.8, w + 1.6), bevel=0.2)
    block(cab, (0, 22.3, 0), (2.6, 3.0, 2.6), bevel=0.2)
    # Service arms toward the rocket axis (local x = -9; rocket skin at x = -5.7).
    x0, x1 = -w / 2, -5.55
    for y in (8.0, 14.0):
        bar(arms, (x0, y, 0), (x1, y, 0), 0.8)
        block(yellow, (x1 + 0.25, y, 0), (0.7, 1.0, 1.4), bevel=0.1)  # 0.1 proud of the arm end (R18)
    # Crew access arm at y = 19.5 (rocket porthole height ~17.4) ending in a white room.
    bar(arms, (x0, 18.2, -0.8), (x1 + 1.4, 18.2, -0.8), 0.5)
    bar(arms, (x0, 18.2, 0.8), (x1 + 1.4, 18.2, 0.8), 0.5)
    block(frame, ((x0 + x1) / 2 + 0.7, 19.6, 0), (x0 - x1 - 1.4, 2.4, 2.2), bevel=0.2)
    box(glass, ((x0 + x1) / 2 + 0.7, 19.9, -1.12), (x0 - x1 - 2.2, 1.0, 0.1))
    block(frame, (x1 + 0.45, 19.6, 0), (0.9, 2.8, 2.8), bevel=0.2)
    # Mast + beacon on top.
    cylinder(mast, (0, h + 0.8, 0), (0, h + 6.0, 0), 0.22, segments=8)
    bar(mast, (-1.2, h + 3.0, 0), (1.2, h + 3.0, 0), 0.16)
    ellipsoid(beacon, (0, h + 6.3, 0), (0.5, 0.55, 0.5), rings=5, segments=10)
    for sx in (-1, 1):
        ellipsoid(beacon, (sx * 3.4, h + 1.0, -3.4), (0.3, 0.3, 0.3), rings=4, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# Pad builds
# ------------------------------------------------------------------------------------------------


def build_fuel_tanks():
    """
    Fuel farm: white sphere tank on legs, orange upright tank with a ladder and a lime level gauge,
    a white capsule tank on saddles, steel pipes with a red valve wheel, and a yellow fuel sign.
    """
    m = Model("A9_FuelTanks", "ground centre; front -Z; footprint 22 x 14; pipe exits at local +X", budget=4000)
    base = m.piece("Base", CONCRETE_DARK)
    white = m.piece("Tank", WHITE)
    orange = m.piece("Orange", ORANGE)
    bands = m.piece("Bands", DEEP_BLUE)
    legs = m.piece("Legs", DARK_STEEL)
    pipes = m.piece("Pipes", STEEL)
    valve = m.piece("Valve", TOY_RED)
    gauge = m.piece("Gauge", LIME, material="Neon")
    sign = m.piece("Sign", HAZARD_YELLOW)
    yellow = sign
    black = m.piece("HazardBlack", HAZARD_BLACK)
    block(base, (0, 0.25, 0), (22.0, 0.5, 14.0), bevel=0.15)
    hazard_band(yellow, black, (0, 0.27, -7.04), (21.6, 0.4, 0.12), stripe=0.7)
    # Sphere tank on four legs + blue equator band.
    sx0, sz0, sy0, sr = -6.0, 2.0, 6.2, 4.3
    ellipsoid(white, (sx0, sy0, sz0), (sr, sr, sr), rings=10, segments=18)
    band(bands, sx0, sz0, sr, sy0 - 0.35, sy0 + 0.35, out=0.12, segments=18)
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        lx, lz = sx0 + 3.4 * math.cos(a), sz0 + 3.4 * math.sin(a)
        cylinder(legs, (lx, 0.5, lz), (lx, sy0, lz), 0.38, segments=8)
        block(legs, (lx, 0.7, lz), (1.2, 0.4, 1.2), bevel=0.1)
    # Orange upright tank (rounded caps) + bands + ladder + level gauge.
    tank(orange, bands, (6.0, 0.5, 2.0), 3.0, 10.5, segments=18, band_count=2)
    ladder(legs, (9.15, 0.5, 2.0), 10.6, width=1.4, facing="x")
    block(legs, (6.0, 6.0, 2.0 - 3.05), (0.9, 7.0, 0.3), bevel=0.08)
    block(gauge, (6.0, 5.2, 2.0 - 3.2), (0.5, 5.0, 0.2), bevel=0.06)
    # Capsule tank lying along X at the front, on two saddles.
    cy, cz = 2.6, -4.3
    cylinder(white, (-4.5, cy, cz), (4.5, cy, cz), 1.8, segments=16)
    for sx in (-1, 1):
        ellipsoid(white, (sx * 4.5, cy, cz), (1.0, 1.8, 1.8), rings=6, segments=16)
        block(legs, (sx * 3.0, 0.95, cz), (0.9, 1.0, 3.0), bevel=0.12)
    # Blue bands around the capsule (axis along X: revolve about Y, then roll 90 deg onto X).
    for x in (-2.0, 2.0):
        revolve(bands, [(1.7, -0.25), (1.92, -0.25), (1.92, 0.25), (1.7, 0.25)], center=(x, cy, cz), segments=16, closed=True, rot=rot_z(90))
    # Pipes: upright tank -> under the sphere; capsule -> exit at +X; valve wheel on the front run.
    pipe(pipes, [(3.0, 1.6, 2.0), (-6.0, 1.6, 2.0), (-6.0, 2.4, 2.0)], 0.32, segments=8)
    pipe(pipes, [(5.4, cy, cz), (8.6, cy, cz), (8.6, 1.4, cz), (11.0, 1.4, cz)], 0.32, segments=8)
    ring_tube(valve, (8.6, 2.0, cz - 0.55), 0.6, 0.18, 0.18, segments=12, axis="Z")
    bar(valve, (8.0, 2.0, cz - 0.55), (9.2, 2.0, cz - 0.55), 0.12)
    # Fuel sign on two posts: yellow board, black flame drop.
    for sx in (-1, 1):
        bar(legs, (-9.0 + sx * 1.0, 0.5, -5.6), (-9.0 + sx * 1.0, 3.2, -5.6), 0.22)
    block(sign, (-9.0, 3.8, -5.6), (2.8, 2.2, 0.25), bevel=0.1)
    # Fuel-drop pictogram: round bottom arc (-150..150 deg) closed by a pointed tip on top.
    flame = [(-9.0 + 0.6 * math.cos(math.radians(a)), 3.55 + 0.6 * math.sin(math.radians(a)), -5.78) for a in range(-240, 61, 30)]
    flame.append((-9.0, 4.8, -5.78))
    prism(black, list(reversed(flame)), (0, 0, 1), 0.08)
    return m


def build_mission_control():
    """
    Mission Control: white building with a full glass front (screen wall + desks visible inside),
    deep-blue mullions and fascia, entrance canopy, roof observatory dome, antenna with a red
    beacon and a planet emblem standing on the roof.
    """
    m = Model("A9_MissionControl", "ground centre; glass front faces -Z; footprint 22 x 14; roof y = 9.6", budget=6000)
    floor = m.piece("Base", CONCRETE)
    walls = m.piece("Walls", WHITE)
    trim = m.piece("Trim", DEEP_BLUE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    screens = m.piece("Screens", SKY_BLUE, material="Neon")
    screens2 = m.piece("ScreensGreen", LIME, material="Neon")
    desks = m.piece("Desks", DARK_STEEL)
    door = m.piece("Door", SKY_BLUE)
    mast = m.piece("Mast", STEEL, material="StudsSmall")
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    planet = m.piece("Planet", ORANGE)
    W, D, H = 22.0, 14.0, 9.0
    zf, zb = -D / 2 + 0.5, D / 2 - 0.5
    block(floor, (0, 0.25, 0), (W + 0.6, 0.5, D + 0.6), bevel=0.15)
    box(walls, (0, 0.5 + H / 2, zb), (W, H, 1.0))
    for sx in (-1, 1):
        box(walls, (sx * (W / 2 - 0.5), 0.5 + H / 2, 0), (1.0, H, D - 2.0))
        # Pilasters run 0.3 up into the roof slab (never flush with the wall tops, R18).
        block(trim, (sx * (W / 2 - 0.6), 0.5 + (H + 0.3) / 2, zf), (1.2, H + 0.3, 1.2), bevel=0.15)
    sill_top, lintel_bot = 1.7, 0.5 + H - 1.8
    block(walls, (0, (0.5 + sill_top) / 2, zf), (W - 1.2, sill_top - 0.5, 1.0), bevel=0.1)
    block(walls, (0, (lintel_bot + 0.5 + H) / 2, zf), (W - 1.2, 0.5 + H - lintel_bot, 1.0), bevel=0.1)
    box(glass, (0, (sill_top + lintel_bot) / 2, zf), (W - 1.4, lintel_bot - sill_top, 0.3))
    for x in (-7.0, -3.5, 3.5, 7.0):
        block(trim, (x, (sill_top + lintel_bot) / 2, zf - 0.25), (0.4, lintel_bot - sill_top, 0.4), bevel=0.06)
    # Roof slab + blue fascia band.
    block(walls, (0, 0.5 + H + 0.3, 0), (W + 0.4, 0.6, D + 0.4), bevel=0.15)
    block(trim, (0, 0.5 + H + 0.35, zf - 0.65), (W + 0.6, 0.8, 0.3), bevel=0.08)  # 0.1 proud of the roof (R18)
    # Entrance: canopy on two posts, door panel in front of the glass.
    block(trim, (0, 5.6, zf - 1.7), (6.0, 0.4, 3.2), bevel=0.12)
    for sx in (-1, 1):
        block(trim, (sx * 2.7, 3.05, zf - 3.0), (0.4, 4.7, 0.4), bevel=0.06)
    block(door, (0, 3.1, zf - 0.35), (3.0, 3.2, 0.2), bevel=0.06)
    bar(mast, (-0.5, 3.0, zf - 0.55), (-0.5, 3.6, zf - 0.55), 0.14)
    # Interior: big screen wall on the back, two rows of desks with monitors.
    block(screens, (0, 5.6, zb - 0.6), (13.0, 3.8, 0.2), bevel=0.05)
    for sx in (-1, 1):
        block(screens2, (sx * 8.4, 5.6, zb - 0.6), (2.6, 2.4, 0.2), bevel=0.05)
    for z in (-1.4, 2.0):
        block(desks, (0, 1.35, z), (16.0, 1.7, 1.4), bevel=0.12)
        for i in range(6):
            x = -6.25 + i * 2.5
            block(screens if i % 2 == 0 else screens2, (x, 2.7, z + 0.3), (1.3, 0.9, 0.14), bevel=0.04, rot=rot_x(-12))
    # Roof: observatory dome with a slit, antenna mast + beacon, planet emblem.
    ry = 0.5 + H + 0.6
    revolve(walls, [(0.0, 0.0), (3.4, 0.0), (3.4, 0.5), (3.1, 1.8), (2.3, 2.9), (1.1, 3.5), (0.0, 3.65)], center=(-6.5, ry, 2.0), segments=18)
    block(trim, (-6.5, ry + 2.3, 2.0), (0.8, 2.8, 6.4), bevel=0.15, rot=rot_x(0))
    cylinder(mast, (7.5, ry, 3.0), (7.5, ry + 7.0, 3.0), 0.2, segments=8)
    for y in (ry + 3.0, ry + 5.0):
        bar(mast, (6.4, y, 3.0), (8.6, y, 3.0), 0.14)
    ellipsoid(beacon, (7.5, ry + 7.35, 3.0), (0.45, 0.5, 0.45), rings=5, segments=8)
    disc_z(trim, (1.5, ry + 2.9, -4.6), 2.5, 0.4, segments=20)
    block(trim, (1.5, ry + 0.3, -4.6), (1.0, 0.6, 1.0), bevel=0.1)
    ellipsoid(planet, (1.5, ry + 2.9, -4.95), (1.3, 1.3, 0.35), rings=6, segments=14)
    revolve(walls, [(1.55, -0.1), (2.1, -0.06), (2.1, 0.06), (1.55, 0.1)], center=(1.5, ry + 2.9, -5.05), segments=20, closed=True, rot=rot_z(20) @ rot_x(75))
    return m


def build_booster_rockets():
    """Three booster rockets (white, orange noses, blue fins) clamped in a steel rack on a slab."""
    m = Model("A9_BoosterRockets", "ground centre; boosters face -Z; footprint 19 x 8; ~19.5 tall", budget=4000)
    base = m.piece("Base", CONCRETE_DARK)
    body = m.piece("Body", WHITE)
    nose = m.piece("Nose", ORANGE)
    fins = m.piece("Fins", DEEP_BLUE)
    redb = m.piece("Stripe", TOY_RED)
    bells = m.piece("Bells", CHARCOAL)
    glow = m.piece("EngineGlow", ORANGE, material="Neon")
    rack = m.piece("Rack", DARK_STEEL)
    lamps = m.piece("Lamps", HAZARD_YELLOW, material="Neon")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    y0 = 0.6
    block(base, (0, y0 / 2, 0), (19.0, y0, 8.0), bevel=0.15)
    hazard_band(yellow, black, (0, 0.32, -4.04), (18.6, 0.48, 0.12), stripe=0.7)
    br = 1.6
    for x in (-6.0, 0.0, 6.0):
        revolve(body, [(0.0, y0 + 1.6), (1.2, y0 + 1.6), (br, y0 + 2.2), (br, y0 + 14.6), (0.0, y0 + 14.6)], center=(x, 0, 0), segments=16)
        revolve(nose, [(0.0, y0 + 14.5), (br + 0.05, y0 + 14.5), (1.5, y0 + 16.1), (1.0, y0 + 17.6), (0.4, y0 + 18.5), (0.0, y0 + 18.8)], center=(x, 0, 0), segments=16)
        band(redb, x, 0, br, y0 + 12.4, y0 + 13.2, out=0.12, segments=16)
        revolve(bells, [(0.0, y0 + 1.7), (0.65, y0 + 1.7), (0.9, y0 + 1.0), (1.2, y0 + 0.2), (0.0, y0 + 0.2)], center=(x, 0, 0), segments=12)
        disc(glow, (x, y0 + 0.08, 0), 1.0, 0.12, segments=12, bevel=0.03)
        for k in range(3):
            a = math.radians(90 + 120 * k)
            dx, dz = math.cos(a), math.sin(a)
            outline = [(1.3, y0 + 5.4), (3.0, y0 + 2.0), (3.0, y0 + 0.0), (1.3, y0 + 1.4)]
            prism(fins, [(x + dx * rr, y, dz * rr) for rr, y in outline], (-dz, 0, dx), 0.5)
    # Rack behind the boosters: posts, two beams, clamp rings.
    zr = 2.9
    for sx in (-1, 1):
        block(rack, (sx * 9.0, y0 + 8.0, zr), (0.9, 16.0, 0.9), bevel=0.12)
        ellipsoid(lamps, (sx * 9.0, y0 + 16.4, zr), (0.4, 0.4, 0.4), rings=4, segments=8)
    for y in (y0 + 6.5, y0 + 11.5):
        bar(rack, (-9.0, y, zr), (9.0, y, zr), 0.7)
        for x in (-6.0, 0.0, 6.0):
            bar(rack, (x, y, zr), (x, y, br + 0.1), 0.45)
            ring_tube(rack, (x, y, 0), br + 0.18, 0.36, 0.5, segments=16)
    return m


def build_satellite_dish():
    """
    Big satellite dish on a concrete block base with a door and ladder; turntable + column mount;
    the white Dish piece (bowl, struts, feed horn, hinge) turns about the pivot's vertical axis.
    """
    m = Model(
        "A9_SatelliteDish",
        "ground centre; dish faces -Z, tilted 40 deg up; Dish bbox centre on the pivot axis (x = 0, z = 0): WorldFx Dish swings it on the column",
        budget=4000,
    )
    base = m.piece("Base", CONCRETE)
    door = m.piece("Door", DEEP_BLUE)
    mount = m.piece("Mount", DARK_STEEL)
    dish = m.piece("Dish", WHITE)
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    block(base, (0, 2.0, 0), (6.4, 4.0, 6.4), bevel=0.25)
    for zs in (-1, 1):
        hazard_band(yellow, black, (0, 0.45, zs * 3.24), (6.0, 0.7, 0.12), stripe=0.6)
    block(door, (0, 1.75, -3.25), (2.0, 2.9, 0.2), bevel=0.06)
    ladder(mount, (3.3, 0.0, 1.2), 4.4, width=1.2, facing="x")
    ellipsoid(beacon, (2.7, 4.25, 2.7), (0.35, 0.35, 0.35), rings=4, segments=8)
    disc(mount, (0, 4.0, 0), 2.6, 0.6, segments=20, bevel=0.12)
    cylinder(mount, (0, 4.6, 0), (0, 8.2, 0), 0.9, segments=14)
    # Dish: hinge + bowl tilted so its axis points -Z and 40 deg up (rot_x(-50)).
    tilt = rot_x(-50)
    c = Vector((0.0, 9.0, 1.9))
    axis = tilt @ Vector((0.0, 1.0, 0.0))
    bar(dish, (0, 8.0, 0), (c.x, c.y, c.z), 0.9)
    bar(dish, (-1.2, c.y, c.z), (1.2, c.y, c.z), 0.7)
    bowl = [(0.0, 0.0), (3.0, 0.42), (6.4, 2.05), (6.8, 2.5), (6.4, 2.62), (3.0, 1.0), (0.0, 0.58)]
    revolve(dish, bowl, center=(c.x, c.y, c.z), segments=28, rot=tilt)
    feed = c + axis * 4.6
    a0 = feed - axis * 0.9
    a1 = feed + axis * 0.5
    cylinder(dish, (a0.x, a0.y, a0.z), (a1.x, a1.y, a1.z), 0.5, segments=10)
    for k in range(3):
        t = math.radians(90 + 120 * k)
        rim = c + tilt @ Vector((6.3 * math.cos(t), 2.2, 6.3 * math.sin(t)))
        bar(dish, (rim.x, rim.y, rim.z), (a0.x, a0.y, a0.z), 0.22)
    return m


# Hinges of the crew's motion groups (model space; WorldFxConfig.Assemblies.A9_AstronautCrew).
CREW_WAVE_SHOULDER = (-7.8, 4.65, 0.0)  # astronaut 1's left shoulder: the wave turns about local Z
CREW_FLAG_POLE = (8.3, 8.4, 1.7)  # the flag pole axis: the flag flutters about local Y


def build_astronaut_crew():
    """Four astronauts (orange / sky / red / lime accents) on a navy crew stage with a mission flag."""
    m = Model("A9_AstronautCrew", "ground centre of the stage; crew faces -Z; footprint 17.6 x 4.6", budget=6000)  # 4 figures x ~1,300 tris
    stage = m.piece("Stage", SPACE_NAVY)
    pc = {
        "suit": m.piece("Suit", WHITE),
        "boots": m.piece("Boots", (104, 110, 124)),
        "visor": m.piece("Visor", GOLD, material="Smooth"),
        "pack": m.piece("Pack", STEEL),
        "shine": m.piece("Shine", WHITE, material="Smooth"),
    }
    accents = [
        m.piece("AccentOrange", ORANGE, material="StudsSmall"),
        m.piece("AccentBlue", SKY_BLUE, material="StudsSmall"),
        m.piece("AccentRed", TOY_RED, material="StudsSmall"),
        m.piece("AccentLime", LIME, material="StudsSmall"),
    ]
    pole = m.piece("Pole", STEEL, material="StudsSmall")
    flag = m.piece("Flag", ORANGE)
    stars = m.piece("Stars", YELLOW, material="Smooth")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    block(stage, (0, 0.2, 0), (17.6, 0.4, 4.6), bevel=0.12)
    hazard_band(yellow, black, (0, 0.2, -2.32), (17.2, 0.34, 0.1), stripe=0.6)
    # 4.2 apart: an astronaut is 3.86 wide across the arm stripes, so neighbours never touch (R18:
    # overlapping accent stripes of two crew members z-fought).
    # Owner R75: the first astronaut's raised arm is its own pieces (WaveSuit / WaveStripe /
    # WaveGlove) so WorldFx waves it about the shoulder (Assemblies.A9_AstronautCrew, hinge
    # CREW_WAVE_SHOULDER); the flag + its star flutter about the pole (hinge CREW_FLAG_POLE).
    wave_pieces = {
        "suit": m.piece("WaveSuit", WHITE),
        "accent": m.piece("WaveStripe", ORANGE, material="StudsSmall"),
        "glove": m.piece("WaveGlove", (104, 110, 124)),
    }
    for i, x in enumerate((-6.3, -2.1, 2.1, 6.3)):
        astronaut(pc, Xf((x, 0.4, 0.0)), accents[i], wave=(i == 0), wave_pieces=wave_pieces if i == 0 else None)
    # Mission flag: pole at the back right + orange flag with a yellow star.
    cylinder(pole, (8.3, 0.4, 1.7), (8.3, 9.4, 1.7), 0.14, segments=8)
    ellipsoid(pole, (8.3, 9.5, 1.7), (0.25, 0.25, 0.25), rings=4, segments=8)
    block(flag, (6.95, 8.4, 1.7), (2.6, 1.8, 0.14), bevel=0.05)
    star(stars, (6.95, 8.4, 1.6), 0.6, 0.1)
    return m


def build_space_elevator():
    """
    Space elevator: round base station, steel column to y ~ 72 with sky-blue rings and three cyan
    Neon ribbons, an orange Climber pod (slides along Y), and a top station with solar wings and a
    red beacon (top ~ 79.0, inside the 80-stud height budget with the 0.5 floor).
    """
    m = Model(
        "A9_SpaceElevator",
        "ground centre; Climber rest y = 22 (bob range 8..36 keeps it on the column); top y ~ 79.0",
        budget=6000,
    )
    station = m.piece("Station", WHITE)
    bands = m.piece("Bands", SPACE_NAVY)
    door = m.piece("Door", DARK_STEEL)
    column = m.piece("Column", STEEL)
    rings = m.piece("Rings", SKY_BLUE)
    ribbon = m.piece("Ribbon", CYAN_GLOW, material="Neon")
    climber = m.piece("Climber", ORANGE)
    panels = m.piece("Panels", DEEP_BLUE, material="Smooth")
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    hazard_ring(yellow, black, (0, 0, 0), 6.0, 7.4, 0.0, 0.12, count=24)
    revolve(station, [(0.0, 0.0), (6.0, 0.0), (6.0, 4.3), (5.4, 5.3), (2.4, 5.9), (0.0, 5.9)], segments=28)
    band(bands, 0, 0, 6.0, 2.4, 3.3, out=0.16, segments=28)
    block(door, (0, 1.7, -5.95), (2.6, 3.4, 0.7), bevel=0.12)
    top_col = 70.5
    cr = 2.0  # column radius: thick enough to read as a landmark from across the plot
    cylinder(column, (0, 5.5, 0), (0, top_col, 0), cr, segments=14)
    revolve(column, [(0.0, 5.6), (3.4, 5.6), (2.9, 7.2), (cr, 7.9), (0.0, 7.9)], segments=14)
    # Four flared struts from the station roof up to the column (a sturdy tripod-style foot).
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        dx, dz = math.cos(a), math.sin(a)
        bar(column, (dx * 4.4, 5.2, dz * 4.4), (dx * (cr + 0.1), 16.0, dz * (cr + 0.1)), 0.55)
    y = 12.0
    while y < top_col - 2:
        ring_tube(rings, (0, y, 0), cr + 0.2, 0.7, 0.7, segments=14)
        y += 8.0
    for k in range(3):
        a = math.radians(90 + 120 * k)
        x, z = (cr + 0.04) * math.cos(a), (cr + 0.04) * math.sin(a)
        # Ribbons stop 0.1 under the column top (both hidden in the top station), so their end caps
        # never share the column's top plane (z-fight audit, R18).
        bar(ribbon, (x, 7.9, z), (x, top_col - 0.1, z), 0.34)
    # Climber pod around the column (rest at y = 22; the client slides it along Y).
    revolve(climber, [(cr + 0.2, 0.0), (3.6, 0.4), (4.2, 1.6), (4.2, 3.4), (3.6, 4.6), (cr + 0.2, 5.0)], center=(0, 22.0, 0), segments=18, closed=True)
    # Top station + solar wings + beacon (beacon top y = 79.0; +0.5 floor = 79.5 < 80 budget).
    ellipsoid(station, (0, 73.6, 0), (4.4, 3.6, 4.4), rings=8, segments=18)
    band(bands, 0, 0, 4.4, 73.1, 74.1, out=0.16, segments=18)
    for sx in (-1, 1):
        bar(column, (sx * 4.2, 73.6, 0), (sx * 5.6, 73.6, 0), 0.5)
        block(panels, (sx * 9.6, 73.6, 0), (8.0, 0.26, 3.4), bevel=0.06)
        for k in (-1.5, -0.5, 0.5, 1.5):
            block(column, (sx * 9.6 + k * 2.0, 73.6, 0), (0.14, 0.34, 3.5), bevel=0.02)
    cylinder(column, (0, 77.0, 0), (0, 78.3, 0), 0.22, segments=6)
    ellipsoid(beacon, (0, 78.6, 0), (0.45, 0.4, 0.45), rings=4, segments=8)
    return m


def build_flight_director():
    """
    Flight Director (Manager): toy figure (area04 proportions) in a white shirt, navy vest and cap,
    headset + clipboard, standing behind a steel console with screens and a big red button.

    Animated NPC (owner R30): the figure is split into rig pieces (Torso*/Head*/ArmL*/ArmR*/LegL*/
    LegR*, see models/_npc_rig.py) so the client ManagerController can walk him around the mat,
    swing his limbs, wave (raises the free left arm) and tap the console. Mat, console, screens and
    button stay static props. The headset is its own piece so it rides the head (its mic boom sits
    nearer the torso bone than the head bone).
    """
    from models._npc_rig import a4_bones, rig_split

    m = Model("A9_FlightDirector", "ground centre of the mat; director faces -Z behind the console", budget=3000)
    mat = m.piece("Mat", SPACE_NAVY)
    console = m.piece("Console", STEEL)
    screens = m.piece("Screens", SKY_BLUE, material="Neon")
    button = m.piece("Button", TOY_RED, material="Neon")
    skin = m.piece("Skin", SKIN)
    shirt = m.piece("Shirt", WHITE)
    pants = m.piece("Pants", (60, 64, 84))
    dark = m.piece("Dark", CHARCOAL)
    cap = m.piece("Cap", DEEP_BLUE)
    accent = m.piece("Vest", SPACE_NAVY, material="StudsSmall")
    block(mat, (0, 0.1, 0.0), (5.2, 0.2, 4.6), bevel=0.06)
    xf = Xf((0.0, 0.2, 0.9))
    toy_figure(
        {"skin": skin, "shirt": shirt, "pants": pants, "dark": dark, "hat": cap, "accent": accent, "paper": shirt},
        xf,
        hat="cap",
        right_arm="clipboard",
        left_arm="down",
        vest=True,
    )
    headset(m.piece("Headset", CHARCOAL), xf)
    # Console: a low desk in front (top y ~ 2.3, so the director shows from the waist up), a slanted
    # control top with a big red button, and two monitors on the desk ends angled toward him.
    block(console, (0, 1.15, -1.15), (4.6, 1.9, 1.3), bevel=0.15)
    block(console, (0, 2.2, -1.25), (4.8, 0.36, 1.7), bevel=0.12, rot=rot_x(14))
    cylinder(button, (0, 2.3, -1.6), (0, 2.65, -1.6), 0.36, segments=12)
    for sx in (-1, 1):
        block(console, (sx * 2.85, 1.15, -0.7), (1.1, 1.9, 2.2), bevel=0.12)
        block(console, (sx * 2.85, 2.95, -0.7), (0.3, 1.3, 1.8), bevel=0.08)
        block(screens, (sx * 2.68, 2.95, -0.7), (0.08, 1.0, 1.5), bevel=0.03)
    # Body-part pieces for the client NPC rig (the clipboard rides the right hand). The torso bone's
    # far end is pulled down to the shoulders (local y 4.2) for classification only, so the mouth
    # bars (local y ~4.9, on the face) score nearer the head; the joint (hip) is unchanged.
    bones = a4_bones(xf, left_arm="down", right_arm="clipboard")
    bones["Torso"] = (bones["Torso"][0], xf.p(0.0, 4.2, 0.0))
    rig_split(
        m,
        bones,
        static=("Mat", "Console", "Screens", "Button"),
        assign={"Headset": "Head"},
        frame=((0.0, 0.2, 0.9), 0.0),
    )
    return m


BUILDERS = {
    "A9_Floor": build_floor,
    "A9_EntryArch": build_entry_arch,
    "A9_LaunchPlatform": build_launch_platform,
    "A9_Rocket": build_rocket,
    "A9_LaunchTower": build_launch_tower,
    "A9_FuelTanks": build_fuel_tanks,
    "A9_MissionControl": build_mission_control,
    "A9_BoosterRockets": build_booster_rockets,
    "A9_SatelliteDish": build_satellite_dish,
    "A9_AstronautCrew": build_astronaut_crew,
    "A9_SpaceElevator": build_space_elevator,
    "A9_FlightDirector": build_flight_director,
}
