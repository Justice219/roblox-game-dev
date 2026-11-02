"""
dino_area05.py — Dino Valley area D5 "Fossil Lab" (World 2 spec §6.2 / §16): a round thatched
lab-museum hut with a puffing stone chimney, a giant friendly long-neck skeleton on a museum plinth,
amber jars, a giant microscope you can climb, egg incubators under a heat lamp, a fossil-dusting
table, a roped dig site, museum banners with bunting, and Dr. Trike (a triceratops in a lab coat).
Every pad purchase is its own model set so each one builds in separately; placement lives in
src/shared/Config/Worlds/Dino/Layouts/Area05.luau (slot-local frame; docs/areas-art.md "Dino D5-D6").

This module ALSO holds the shared Dino Valley helpers used by dino_area06.py (and free for the other
Dino art builders to import — read-only, no side effects):
    DINO palette constants (fern / sand / mossy stone / amber / bone / lava / basalt ...)
    biped_geometry / body_shell / trike_head / goggles / hard_hat / back_bumps   clothes + species
                                          details on W6's shared body (models.dino_area01.dino_biped)
    dino_arch(...)                        double-sided (R17) stone-post + log-beam entry arch
    fern / palm / boulder / bone_shape / egg / ribbon / place_new   scenery + shape primitives

Kid-friendly rules (spec §2): every dino is round, big-eyed and smiling; no teeth, claws or gore;
bones are chunky cartoon dog-bones; the skeleton is a friendly museum display.

Models (key: pivot / notes)                                            build key
    D5_Floor           SLOT ORIGIN pivot (layout cf = identity); top y = 0.5   base
    D5_EntryArch       ground centre between the posts; "FOSSIL LAB"        base
    D5_LabHut          PRODUCER: ground centre (slot (0, 0.5, 50)); door -Z  D5_LabHut
                       chimney SteamA puffs; Lamp = porch lanterns (light)
    D5_AmberJars       ground centre; shelf faces -Z                         D5_AmberJars
    D5_Microscope      ground centre of the platform; profile faces -Z       D5_Microscope
    D5_Incubators      ground centre; Wobble* = the eggs (W10 row)           D5_Incubators
    D5_DustingBrushes  ground centre; table faces -Z                         D5_DustingBrushes
    D5_Skeleton        HERO: ground centre of the plinth; head toward -X     D5_Skeleton
    D5_DigSite         ground centre of the pit                              D5_DigSite
    D5_DrTrike         Manager: figure on a mat + specimen desk              D5_DrTrike
    D5_MuseumBanners   ground centre of the walkway between two poles        D5_MuseumBanners
                       Pennant* = bunting (existing WorldFx row)

Budgets (docs/world-art.md §4, spec §15): the fully built area <= 28k triangles; hero (skeleton)
<= 6k; machines / buildings <= 5k; manager <= 3k.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import Model, SKY_BLUE, STEEL, TOY_RED, WHITE, br, rb
from snkit.kit import block, disc, ladder
from snkit.shapes import bar, cylinder, ellipsoid, prism, revolve, ring_tube, rot_x, rot_y, rot_z

from models._critter_kit import circle_points, oriented_ellipsoid, plate, surface, tube
from models.area01 import FONT_ROWS, LOT_TOP, SLOT_PIVOT, lot_stripes, text_cells
from models.area04 import Xf, _hash
from models.area09 import cable, text_both
from models.dino_area01 import dino_biped, dino_bones

# ------------------------------------------------------------------------------------------------
# Dino Valley palette (spec §2: fern green / sand / mossy stone / amber / bone cream / lava candy
# orange; organic round shapes, thatch, logs, bamboo, rope; no grey metal except tiny accents).
# ------------------------------------------------------------------------------------------------

FERN = (92, 184, 74)
FERN_DARK = (58, 140, 62)
MOSS = (110, 170, 70)
SAND = (238, 208, 150)
SAND_DARK = (220, 184, 124)
DIRT = (178, 128, 82)
STONE_WARM = (184, 172, 156)
STONE_LIGHT = (210, 200, 184)
STONE_DARK = (132, 122, 114)
AMBER = (255, 166, 40)
AMBER_LIGHT = (255, 208, 120)
BONE = (250, 238, 208)
BONE_SHADE = (228, 210, 172)
LOG = (170, 112, 64)
LOG_DARK = (126, 82, 48)
LOG_LIGHT = (232, 196, 140)
THATCH = (226, 186, 100)
THATCH_DARK = (196, 150, 72)
BAMBOO = (200, 204, 104)
ROPE = (218, 190, 136)
ADOBE = (248, 228, 190)
CLAY = (222, 118, 74)
LAVA = (255, 122, 36)
LAVA_LIGHT = (255, 176, 84)
BASALT = (88, 78, 86)
BASALT_LIGHT = (122, 110, 114)
OBSIDIAN = (70, 48, 96)
GOLD = (255, 196, 48)
GOLD_LIGHT = (255, 226, 120)
GOLD_DARK = (214, 150, 34)
SHINE = (255, 255, 255)
EYE = (40, 34, 46)
BLUSH = (255, 150, 160)
TRIKE = (112, 168, 236)  # Dr. Trike: soft sky blue (distinct from Captain Ptera teal / Para Pete green)
TRIKE_FRILL = (255, 158, 70)

SLOT_W = 104.0
SLOT_D = 70.0
T = LOT_TOP  # the area floor plate top (every model in the layout stands at y = T)


# ------------------------------------------------------------------------------------------------
# Generic helpers
# ------------------------------------------------------------------------------------------------


def place_new(pieces, build, xf=None, scale=1.0):
    """
    Draw a sub-assembly at the origin, then move ONLY the vertices it added: p' = xf.rot @ (p * scale)
    + xf.base. Lets the figure / fern / palm helpers author in a simple local frame (front -Z, feet at
    y = 0) and still land anywhere, any yaw, any size, without touching geometry drawn before.

    pieces: every Piece the callback may touch (duplicates are fine).
    build:  zero-argument callable that draws (and may return a value, passed through).

    Example: place_new([trunk, leaves], lambda: palm(trunk, leaves, (0, 0, 0)), Xf((40, 0.5, 60), 30))
    """
    unique = {id(p): p for p in pieces}.values()
    before = [(p, set(p.bm.verts)) for p in unique]
    result = build()
    if xf is not None or scale != 1.0:
        rot = xf.rot if xf is not None else rot_y(0)
        base = xf.base if xf is not None else Vector((0, 0, 0))
        for p, old in before:
            for v in p.bm.verts:
                if v not in old:
                    q = Vector(br(v.co)) * scale
                    v.co = rb(rot @ q + base)
    return result


def leaf(piece, base, yaw, tilt, length, width, thick=0.12):
    """
    One fern / palm frond: a pointed leaf plate from `base`, heading `yaw` degrees (0 = -Z, CCW from
    above like Xf) and climbing `tilt` degrees (negative droops). 28 triangles.
    """
    a, t = math.radians(yaw), math.radians(tilt)
    d = Vector((-math.sin(a) * math.cos(t), math.sin(t), -math.cos(a) * math.cos(t)))
    up = Vector((0, 1, 0))
    n = (up - d * up.dot(d)).normalized()
    w, L = width, length
    outline = [(0, 0), (w * 0.45, L * 0.2), (w * 0.5, L * 0.5), (w * 0.3, L * 0.8), (0, L), (-w * 0.3, L * 0.8), (-w * 0.5, L * 0.5), (-w * 0.45, L * 0.2)]
    plate(piece, outline, base, tuple(n), up=tuple(d), thickness=thick)


def fern(piece, base, size=1.0, fronds=5, seed=0):
    """
    Low fern clump: `fronds` leaves fanned round `base` (ground point), tilted up 25-40 deg. Cheap
    jungle filler (~28 triangles per frond). size scales the frond length (3.2 studs at 1.0).
    """
    for k in range(fronds):
        yaw = k * 360.0 / fronds + _hash(seed, k) * 30.0
        tilt = 25.0 + _hash(seed + 3, k) * 15.0
        leaf(piece, base, yaw, tilt, 3.2 * size * (0.85 + 0.3 * _hash(seed + 5, k)), 1.1 * size)


def palm(trunk, leaves, nuts, base, height=11.0, lean=6.0, seed=0):
    """
    Cartoon palm: 4 stacked, slightly shrinking trunk drums leaning `lean` degrees toward +X, a crown of
    6 drooping two-part fronds and 3 coconuts. ~480 triangles. base = ground point.
    """
    bx, by, bz = base
    seg = height / 4
    lx = math.sin(math.radians(lean))
    p0 = Vector((bx, by, bz))
    for i in range(4):
        a = p0 + Vector((lx * seg * i, seg * i, 0))
        b = p0 + Vector((lx * seg * (i + 1), seg * (i + 1) + 0.15, 0))
        cylinder(trunk, tuple(a), tuple(b), 0.62 - 0.07 * i, segments=6, radius_b=0.5 - 0.07 * i)
    top = p0 + Vector((lx * height, height + 0.1, 0))
    for k in range(6):
        yaw = k * 60.0 + _hash(seed, k) * 20.0
        mid_len = 3.0
        a = math.radians(yaw)
        d = Vector((-math.sin(a), 0, -math.cos(a)))
        leaf(leaves, tuple(top), yaw, 22.0, mid_len, 1.6)
        tip_base = top + d * (mid_len * math.cos(math.radians(22))) + Vector((0, mid_len * math.sin(math.radians(22)), 0))
        leaf(leaves, tuple(tip_base - d * 0.3), yaw, -38.0, 3.4, 1.5)
    for k in range(3):
        a = math.radians(k * 120.0 + 20.0)
        ellipsoid(nuts, (top.x + 0.55 * math.cos(a), top.y - 0.35, top.z + 0.55 * math.sin(a)), (0.38, 0.38, 0.38), rings=3, segments=5)


def boulder(piece, center, size, seed=0, rings=4, segments=7):
    """Lumpy round rock: an ellipsoid whose vertices are pushed in/out by a deterministic hash."""

    def deform(x, y, z):
        k = 0.82 + 0.3 * _hash(seed + x * 3.1, y * 5.7 + z * 2.3)
        return (x * k, y * (0.9 + 0.2 * _hash(seed + 7, x + z)), z * k)

    ellipsoid(piece, center, size, rings=rings, segments=segments, deform=deform)


def bone_shape(piece, a, b, radius, knob=None, segments=8):
    """
    Chunky cartoon dog-bone from a to b (spec §2: bones are cream dog-bone silhouettes): a round
    shaft plus two knobs at each end, splayed perpendicular to the shaft in the plane that contains
    +Y (or +Z for an upright bone). ~180 triangles.
    """
    a, b = Vector(a), Vector(b)
    d = (b - a).normalized()
    ref = Vector((0, 1, 0)) if abs(d.y) < 0.9 else Vector((0, 0, 1))
    side = (ref - d * ref.dot(d)).normalized()
    k = knob if knob is not None else radius * 1.45
    cylinder(piece, tuple(a), tuple(b), radius, segments=segments)
    for end, out in ((a, -d), (b, d)):
        for s in (-1, 1):
            c = end + out * (k * 0.25) + side * (s * k * 0.62)
            ellipsoid(piece, tuple(c), (k, k, k), rings=4, segments=7)


def egg(piece, center, radius, rings=7, segments=10):
    """Cartoon egg: an ellipsoid 1.3x taller than wide, narrower at the top. center = egg centre."""

    def deform(x, y, z):
        k = 1.0 - 0.16 * (y / (radius * 1.3))
        return (x * k, y, z * k)

    ellipsoid(piece, center, (radius, radius * 1.3, radius), rings=rings, segments=segments, deform=deform)


def ribbon(piece, path, normals, widths, thick=0.12):
    """
    Flat strip laid on a surface (lava streaks, banners on a curve): for each path point p (with the
    surface's outward normal n and a width w) a 4-point cross-section [p +- side*w/2, the same pushed
    -n*thick] is lofted into a closed band. The strip's top sits ON p; put p a little outside the
    surface it follows (never flush: owner R18).
    """
    from snkit.shapes import loft

    pts = [Vector(p) for p in path]
    sections = []
    for i, p in enumerate(pts):
        t = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        n = Vector(normals[i]).normalized()
        s = t.cross(n).normalized()
        w = widths[i] / 2
        q = n * thick
        sections.append([tuple(p + s * w), tuple(p - s * w), tuple(p - s * w - q), tuple(p + s * w - q)])
    loft(piece, sections)


def text_both_at(piece, lines, cx, cy, z_front, z_back, cell, depth):
    """
    area09.text_both (block letters on BOTH faces, owner R17) centred on x = cx instead of x = 0.
    Example: text_both_at(letters, "DIG", -5.3, 3.3, -5.22, -4.98, 0.12, 0.08)
    """
    place_new([piece], lambda: text_both(piece, lines, cy, z_front, z_back, cell, depth), Xf((cx, 0.0, 0.0)))


# ------------------------------------------------------------------------------------------------
# Manager accessories on W6's SHARED Dino body (models.dino_area01.dino_biped): every Dino manager
# (D1-D6) and the D6 statue use that one body so proportions and rig joints match (W6 / W7 request).
# These helpers only add clothes / species details from the dino_biped anchors.
# ------------------------------------------------------------------------------------------------


def biped_geometry(a):
    """
    Derived shapes of a dino_biped (same formulas as dino_area01.dino_biped): head + snout ellipsoids,
    body ellipsoid and each arm's shoulder / elbow / hand.
    Returns {"head": (c, r), "snout": (c, r), "body": (c, r), "arms": {"left"/"right": (shoulder, elbow, hand)}}.
    """
    hc, hr = a["head"], a["head_r"]
    tip = a["snout_tip"]
    snout_c = (0.0, hc[1] - hr[1] * 0.3, hc[2] - hr[2] * 0.72)
    snout_r = (hr[0] * 0.72, hr[1] * 0.52, snout_c[2] - tip[2])
    arms = {}
    for side, hand in a["hands"].items():
        sx = -1 if side == "left" else 1
        shoulder = Vector((sx * a["shoulder_x"], a["shoulder_y"], a["shoulder_z"]))
        d = (Vector(hand) + Vector((0, 0, 0.1)) - shoulder) / 1.15
        arms[side] = (shoulder, shoulder + d * 0.6, Vector(hand))
    return {"head": (hc, hr), "snout": (snout_c, snout_r), "body": (a["body_c"], a["body"]), "arms": arms}


def body_shell(shell, front, a, lapel=None, grow=1.04):
    """
    Coat / vest over a dino_biped body: a shell ellipsoid `grow` x the body (it fully contains the body,
    so no face is shared: R18) plus a cream `front` oval showing through the open front, and optional
    `lapel` tubes along the opening (a lab coat).
    """
    g = biped_geometry(a)
    bc, br = g["body"]
    sr = (br[0] * grow, br[1] * grow, br[2] * grow)
    ellipsoid(shell, bc, sr, rings=8, segments=12)
    fc = (0.0, bc[1] - br[1] * 0.1, bc[2] - sr[2] * 0.86)
    oriented_ellipsoid(front, fc, (br[0] * 0.5, br[1] * 0.62, 0.32), normal=(0, 0, -1), rings=5, segments=10)
    if lapel is not None:
        for side in (-1, 1):
            pts = []
            for pitch, yaw in ((44, 26), (22, 30), (0, 31), (-22, 27)):
                p, n = surface(bc, sr, side * yaw, pitch)
                pts.append(tuple(p + n * 0.04))
            tube(lapel, pts, 0.09, sides=4)


def trike_head(frill, horns, a):
    """Triceratops details on a dino_biped head: a scalloped frill fan with cream knobs + three soft horns."""
    g = biped_geometry(a)
    (hc, hr), (sc, sr) = g["head"], g["snout"]
    k = hr[0] / 1.12
    pts = []
    for i, deg in enumerate(range(-20, 201, 20)):
        r = (1.7 if i % 2 == 0 else 1.5) * k
        pts.append((r * math.cos(math.radians(deg)), r * math.sin(math.radians(deg)) + 0.15 * k))
    pts += [(-0.7 * k, -0.45 * k), (0.7 * k, -0.45 * k)]
    fo = Vector((0.0, hc[1] + 0.32 * k, hc[2] + hr[2] * 0.82))
    fn = Vector((0.0, 0.42, 1.0)).normalized()
    plate(frill, pts, tuple(fo), tuple(fn), up=(0, 1, 0), thickness=0.2)
    from models._critter_kit import frame

    fs, fu, _ = frame(tuple(fn))
    for deg in range(0, 181, 36):
        q = fo + fs * (1.7 * k * math.cos(math.radians(deg))) + fu * (1.7 * k * math.sin(math.radians(deg)) + 0.15 * k) + fn * 0.02
        ellipsoid(horns, tuple(q), (0.2, 0.2, 0.16), rings=3, segments=5)
    for side in (-1, 1):
        p, n = surface(hc, hr, side * 22.0, 34.0)
        cylinder(horns, tuple(p - n * 0.1), tuple(p + Vector((side * 0.12, 0.55, -0.75))), 0.2, segments=6, radius_b=0.04)
    p, n = surface(sc, sr, 0.0, 50.0)
    cylinder(horns, tuple(p - n * 0.1), tuple(p + Vector((0.0, 0.45, -0.3))), 0.17, segments=6, radius_b=0.04)


def goggles(strap, lens, a):
    """Lab goggles pushed up on the forehead: a strap ring round the head + two round lenses."""
    hc, hr = biped_geometry(a)["head"]
    y = 0.42
    f = math.sqrt(1 - (y / hr[1]) ** 2)
    rx, rz = hr[0] * f + 0.03, hr[2] * f + 0.03
    pts = circle_points((hc[0], hc[1] + y, hc[2]), rx, normal=(0, 1, 0), segments=14, up=(0, 0, -1), squash=rz / rx)
    tube(strap, pts, 0.07, sides=4, closed=True)
    for side in (-1, 1):
        p, n = surface(hc, hr, side * 24.0, 26.0)
        oriented_ellipsoid(strap, tuple(p + n * 0.06), (0.33, 0.29, 0.14), normal=tuple(n), rings=4, segments=8)
        oriented_ellipsoid(lens, tuple(p + n * 0.16), (0.24, 0.21, 0.06), normal=tuple(n), rings=3, segments=8)


def hard_hat(hat, band, a):
    """Round hard hat (dome + brim) with a coloured band, sitting on a dino_biped head."""
    hc, hr = biped_geometry(a)["head"]
    top = a["head_top"]
    cx, cz = hc[0], hc[2] + 0.05
    k = hr[0] / 1.1
    revolve(hat, [(0.0, top + 0.55 * k), (0.55 * k, top + 0.47 * k), (0.86 * k, top + 0.22 * k), (0.98 * k, top - 0.18), (0.0, top - 0.18)], center=(cx, 0, cz), segments=12)
    revolve(hat, [(0.92 * k, top - 0.3), (1.32 * k, top - 0.3), (1.32 * k, top - 0.16), (0.92 * k, top - 0.16)], center=(cx, 0, cz), segments=12, closed=True)
    revolve(band, [(0.93 * k, top - 0.16), (1.03 * k, top - 0.16), (1.0 * k, top + 0.02), (0.9 * k, top + 0.02)], center=(cx, 0, cz), segments=12, closed=True)


def back_bumps(piece, a):
    """Rounded T. rex back bumps from the neck down the spine (+Z side of the body)."""
    bc, br = biped_geometry(a)["body"]
    for pitch, r in ((55.0, 0.26), (30.0, 0.3), (5.0, 0.3), (-20.0, 0.26)):
        p, n = surface(bc, br, 180.0, pitch)
        ellipsoid(piece, tuple(p - n * 0.05), (0.18, r, r), rings=3, segments=5)


def clipboard(board, paper, center, yaw=0.0, tilt=-18.0, size=(1.3, 1.6)):
    """Clipboard held in front of the chest: board + proud paper + clip (paper colour). ~40 tris."""
    rot = rot_y(yaw) @ rot_x(tilt)
    w, h = size
    block(board, center, (w, h, 0.12), bevel=0.04, rot=rot)
    off = rot @ Vector((0, -0.05, -0.08))
    block(paper, (center[0] + off.x, center[1] + off.y, center[2] + off.z), (w - 0.25, h - 0.35, 0.05), bevel=0.0, rot=rot)
    off = rot @ Vector((0, h / 2 - 0.1, -0.1))
    block(board, (center[0] + off.x, center[1] + off.y, center[2] + off.z), (0.5, 0.22, 0.12), bevel=0.03, rot=rot)


# ------------------------------------------------------------------------------------------------
# Dino entry arch (R17: lettered on both faces)
# ------------------------------------------------------------------------------------------------


def dino_arch(key, lines, *, inner=20.0, budget=6000, max_cell=0.6, letter_color=BONE, stone_colors=(STONE_WARM, STONE_DARK), topper=None):
    """
    Dino Valley entry arch: two posts of three stacked, slightly twisted mossy stones, a big log
    beam resting on them (rope lashings, pale cut ends), a plank sign board standing on the beam
    with block letters on BOTH faces (text_both, owner R17), stone torch bowls with soft flames on
    the beam ends and a fern at each post foot. `topper(m, info)` adds the area's own crest.

    inner: clear walkway width between the posts. Pivot: ground centre under the board, front -Z.
    stone_colors: (light, dark) post stones (D6 uses basalt). max_cell caps the letter cell size.
    Returns the Model with `arch_info` = {post_x, post_w, beam_y, board_y, board_h, board_w, top_y, half}.
    """
    m = Model(key, "ground centre between the posts; sign reads correctly from -Z (road) and +Z (area)", budget=budget)
    stone = m.piece("Stone", stone_colors[0])
    stone2 = m.piece("StoneDark", stone_colors[1])
    moss = m.piece("Moss", MOSS)
    log = m.piece("Log", LOG)
    ends = m.piece("LogEnds", LOG_LIGHT, material="StudsSmall")
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    plank = m.piece("Planks", LOG_DARK)
    plank2 = m.piece("PlanksDark", (104, 66, 38))
    letters = m.piece("Letters", letter_color, material="Smooth")
    bowl = m.piece("Bowls", STONE_DARK)
    flame = m.piece("Flame", AMBER_LIGHT, material="Neon")
    leaves = m.piece("Fern", FERN)
    post_w = 3.6
    px = inner / 2 + post_w / 2
    # Posts: three stones each (alternating tones, small twists so they read hand-stacked).
    y = 0.0
    for i, (grow, h) in enumerate(((0.9, 3.4), (0.4, 3.2), (0.0, 3.0))):
        for sx in (-1, 1):
            piece = stone if (i + (sx > 0)) % 2 == 0 else stone2
            twist = rot_y((7.0 if i % 2 == 0 else -6.0) * sx)
            block(piece, (sx * px, y + h / 2, 0), (post_w + grow, h, post_w + grow), bevel=0.4, rot=twist)
        y += h - 0.05
    post_top = y + 0.05
    for sx in (-1, 1):
        block(moss, (sx * px, post_top + 0.2, 0), (post_w + 0.3, 0.5, post_w + 0.3), bevel=0.2)
    # Log beam on the moss caps, cut ends proud of the log, rope lashings by each post.
    beam_y = post_top + 0.45 + 0.95
    half = px + post_w / 2 + 1.3
    cylinder(log, (-half, beam_y, 0), (half, beam_y, 0), 0.95, segments=10)
    for sx in (-1, 1):
        revolve(ends, [(0.0, -0.06), (0.8, -0.06), (0.8, 0.06), (0.0, 0.06)], center=(sx * (half + 0.02), beam_y, 0), segments=10, rot=rot_z(90))
        for dx in (-1.1, 1.1):
            revolve(rope, [(0.9, -0.16), (1.1, -0.16), (1.1, 0.16), (0.9, 0.16)], center=(sx * px + dx, beam_y, 0), segments=10, closed=True, rot=rot_z(90))
    # Sign board: three planks standing on the beam, letters on both faces.
    lines = [lines] if isinstance(lines, str) else list(lines)
    board_w = inner + 2 * post_w - 1.0
    pad = 0.9
    cell = min(max_cell, (board_w - 2 * pad) / max(text_cells(line) for line in lines))
    rows = len(lines) * FONT_ROWS + (len(lines) - 1) * 2
    board_h = rows * cell + 2 * pad
    board_y0 = beam_y + 0.6
    depth = 0.9
    count = 3
    ph = board_h / count
    for i in range(count):
        block(plank if i % 2 == 0 else plank2, (0, board_y0 + ph * (i + 0.5), 0), (board_w - (0.3 if i % 2 else 0.0), ph, depth), bevel=0.15)
    board_y = board_y0 + board_h / 2
    text_both(letters, lines, board_y, -depth / 2, depth / 2, cell, 0.3)
    top_y = board_y0 + board_h
    # Torch bowls + flames on the beam ends (small soft flames; the piece is Neon but spread wide, so
    # MeshPlacement.resolveGlow renders it as bright Smooth: owner R19).
    for sx in (-1, 1):
        bx = sx * (half - 0.9)
        revolve(bowl, [(0.0, 0.0), (0.5, 0.0), (1.05, 0.7), (0.95, 0.85), (0.0, 0.85)], center=(bx, beam_y + 0.85, 0), segments=10)
        ellipsoid(flame, (bx, beam_y + 2.3, 0), (0.85, 1.3, 0.85), rings=5, segments=8)
        ellipsoid(flame, (bx + 0.2 * sx, beam_y + 3.45, 0.05), (0.42, 0.7, 0.42), rings=4, segments=6)
    # Ferns at the post feet (outer side + inner back corner).
    for sx in (-1, 1):
        fern(leaves, (sx * (px + post_w / 2 + 0.5), 0.0, -0.6), size=0.8, fronds=5, seed=11 + sx)
    m.arch_info = {
        "post_x": px,
        "post_w": post_w,
        "beam_y": beam_y,
        "board_y": board_y,
        "board_h": board_h,
        "board_w": board_w,
        "top_y": top_y,
        "half": half,
    }
    if topper is not None:
        topper(m, m.arch_info)
    return m


# ------------------------------------------------------------------------------------------------
# D5 base: floor + entry arch
# ------------------------------------------------------------------------------------------------

HUT_Z = 50.0  # slot z of the lab hut centre (layout HUT)
PLAZA_R = 15.0


def build_floor():
    """
    Fossil Lab ground (slot-origin pivot): two-tone sand stripes, stepping-stone flagstones from the
    road to a round flagstone plaza around the lab hut (slot (0, 50)), a low mossy stone wall on the
    sides and back (open to the road), ferns in the corners and two palms in the back corners.
    """
    m = Model("D5_Floor", SLOT_PIVOT, budget=4000)
    sand = m.piece("Sand", SAND)
    sand2 = m.piece("SandDark", SAND_DARK)
    path = m.piece("Flagstones", STONE_LIGHT)
    plaza = m.piece("Plaza", STONE_WARM)
    wall = m.piece("Wall", STONE_DARK)
    moss = m.piece("Moss", MOSS)
    leaves = m.piece("Ferns", FERN)
    trunk = m.piece("Trunks", LOG)
    palm_leaves = m.piece("PalmLeaves", FERN_DARK)
    nuts = m.piece("Coconuts", LOG_DARK, material="StudsSmall")
    lot_stripes(sand, sand2, -SLOT_W / 2, SLOT_W / 2, 0.0, SLOT_D, stripe=13.0, top=T, along="z")
    # Stepping stones: pairs of slightly irregular slabs (top T + 0.1) up to the plaza edge.
    z = 1.6
    i = 0
    while z < HUT_Z - PLAZA_R - 1.4:
        for sx in (-1, 1):
            w = 3.1 + 0.6 * _hash(i, sx)
            d = 2.0 + 0.4 * _hash(i + 9, sx)
            block(path, (sx * 1.75 + (_hash(i, 3) - 0.5) * 0.4, T + 0.05, z), (w, 0.1, d), bevel=0.0, rot=rot_y((_hash(i, sx + 5) - 0.5) * 10))
        z += 2.75
        i += 1
    # Plaza: round flagstone disc (top T + 0.06) — the hut stands on it.
    disc(plaza, (0, T, HUT_Z), PLAZA_R, 0.06, segments=28, bevel=0.0)
    # Low wall: back + sides from z 20 (the pad strip and the front stay open), moss caps proud 0.1.
    wh = 2.0
    for x0, x1 in ((-52, -26), (-26, 0), (0, 26), (26, 52)):
        block(wall, ((x0 + x1) / 2, T + wh / 2, SLOT_D - 0.7), (x1 - x0, wh, 1.4), bevel=0.3)
        block(moss, ((x0 + x1) / 2, T + wh + 0.15, SLOT_D - 0.7), (x1 - x0 - 0.6, 0.3, 1.6), bevel=0.1)
    for sx in (-1, 1):
        x = sx * (SLOT_W / 2 - 0.7)
        for z0, z1 in ((20.0, 45.0), (45.0, SLOT_D - 1.4)):
            block(wall, (x, T + wh / 2, (z0 + z1) / 2), (1.4, wh, z1 - z0), bevel=0.3)
            block(moss, (x, T + wh + 0.15, (z0 + z1) / 2), (1.6, 0.3, z1 - z0 - 0.6), bevel=0.1)
    # Ferns along the walls + palms in the back corners.
    for k, (x, z) in enumerate(((47.5, 22.5), (-47.5, 22.5), (47.5, 44.0), (-47.5, 44.0), (14.0, 66.0), (-14.0, 66.0))):
        fern(leaves, (x, T, z), size=1.0, fronds=5, seed=k * 7)
    for k, (x, z, lean) in enumerate(((46.5, 64.0, -8.0), (-46.5, 64.0, 8.0))):
        palm(trunk, palm_leaves, nuts, (x, T, z), height=12.0, lean=lean, seed=k * 5 + 2)
    return m


def _bone_crest(m, info):
    """D5 arch crest: a giant cartoon bone lying along the board top, with an amber gem at its centre."""
    bone = m.piece("Bone", BONE)
    gem = m.piece("Gem", AMBER, material="Smooth")
    y = info["top_y"] + 0.9
    half = info["board_w"] * 0.32
    bone_shape(bone, (-half, y, 0), (half, y, 0), 0.55, knob=0.8, segments=8)
    oriented_ellipsoid(gem, (0, y, -0.55), (0.55, 0.65, 0.25), normal=(0, 0, -1), rings=4, segments=6)
    oriented_ellipsoid(gem, (0, y, 0.55), (0.55, 0.65, 0.25), normal=(0, 0, 1), rings=4, segments=6)


def build_entry_arch():
    """'FOSSIL LAB' arch (dino_arch) crowned with a giant cartoon bone + amber gem (both faces)."""
    return dino_arch("D5_EntryArch", "FOSSIL LAB", inner=20.0, budget=5000, topper=_bone_crest)


# ------------------------------------------------------------------------------------------------
# Producer: the Lab Hut
# ------------------------------------------------------------------------------------------------

HUT_R = 9.5  # wall radius
HUT_TOP = 22.0  # bone finial top (local y)


def _round_window(glass, frame_piece, center, normal, radius):
    """Round porthole on a curved wall: flat dark glass lens + log frame ring (normal = outward)."""
    oriented_ellipsoid(glass, center, (radius, radius, 0.1), normal=normal, rings=4, segments=10)
    n = Vector(normal).normalized()
    pts = circle_points(tuple(Vector(center) + n * 0.05), radius + 0.12, normal=tuple(n), segments=10, up=(0, 1, 0))
    tube(frame_piece, pts, 0.16, sides=4, closed=True)


def build_lab_hut():
    """
    Fossil Lab (producer): a round adobe hut on a stone foundation ring, ten log posts, a three-tier
    thatched roof with a bone weathervane on top, four round windows, a big round-top door with a
    bone emblem and two amber porch lanterns, and a stone chimney puffing cartoon steam.
    """
    m = Model(
        "D5_LabHut",
        "ground centre (layout: slot (0, 0.5, 50)); door faces -Z (door front z = -10.6); SteamA puffs on the "
        "chimney; Lamp = porch lanterns (WorldFx Bulb light)",
        budget=5000,
    )
    base = m.piece("Foundation", STONE_WARM)
    walls = m.piece("Walls", ADOBE)
    posts = m.piece("Posts", LOG)
    thatch = m.piece("Thatch", THATCH)
    thatch2 = m.piece("ThatchDark", THATCH_DARK)
    door = m.piece("Door", LOG_DARK)
    glass = m.piece("Windows", (70, 120, 140), material="Smooth")
    bone = m.piece("Bone", BONE)
    chimney = m.piece("Chimney", STONE_DARK)
    steam = m.piece("SteamA", (246, 246, 250), material="Smooth")
    lamp = m.piece("Lamp", AMBER_LIGHT, material="Neon")
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    r = HUT_R
    revolve(base, [(0.0, 0.0), (r + 0.8, 0.0), (r + 0.8, 0.8), (r + 0.5, 1.1), (0.0, 1.1)], segments=20)
    revolve(walls, [(0.0, 1.0), (r, 1.0), (r, 9.2), (0.0, 9.2)], segments=20)
    # Log posts round the wall (skipping the door bay) + a log ring under the eaves.
    for k in range(10):
        a = math.radians(-90 + 36 * k + 18)
        x, z = (r + 0.15) * math.cos(a), (r + 0.15) * math.sin(a)
        cylinder(posts, (x, 1.05, z), (x, 8.7, z), 0.38, segments=6)
    ring_tube(posts, (0, 8.75, 0), r + 0.1, 0.7, 0.6, segments=20)
    # Thatched roof: three stacked cones, alternating straw tones, each with a deep overhang.
    revolve(thatch, [(0.0, 8.5), (12.6, 8.5), (12.6, 9.2), (7.0, 13.9), (0.0, 13.9)], segments=20)
    revolve(thatch2, [(0.0, 12.7), (9.0, 12.7), (9.0, 13.4), (4.6, 17.6), (0.0, 17.6)], segments=18)
    revolve(thatch, [(0.0, 16.5), (5.7, 16.5), (5.7, 17.2), (0.7, 21.1), (0.0, 21.2)], segments=16)
    # Bone weathervane: pole + a cartoon bone on top.
    cylinder(posts, (0, 20.6, 0), (0, HUT_TOP - 0.8, 0), 0.22, segments=6)
    bone_shape(bone, (-1.3, HUT_TOP - 0.45, 0), (1.3, HUT_TOP - 0.45, 0), 0.3, knob=0.42, segments=6)
    # Door: round-top door slab proud of the curved wall, log jambs + lintel, bone emblem, step.
    dz = -r - 0.45
    block(door, (0, 3.6, dz), (3.6, 5.2, 1.0), bevel=0.15)
    revolve(door, [(0.0, -0.5), (1.8, -0.5), (1.8, 0.5), (0.0, 0.5)], center=(0, 6.2, dz), segments=12, rot=rot_x(90))
    for sx in (-1, 1):
        cylinder(posts, (sx * 2.45, 1.05, dz - 0.35), (sx * 2.45, 7.0, dz - 0.35), 0.38, segments=6)
    cylinder(posts, (-3.0, 7.25, dz - 0.35), (3.0, 7.25, dz - 0.35), 0.42, segments=6)
    bone_shape(bone, (-0.9, 4.3, dz - 0.62), (0.9, 4.3, dz - 0.62), 0.2, knob=0.3, segments=6)
    block(base, (0, 0.55, dz - 1.4), (5.4, 1.1, 1.8), bevel=0.2)
    # Porch lanterns hanging from the lintel ends (rope + small glowing amber jars).
    for sx in (-1, 1):
        x = sx * 3.4
        bar(rope, (x, 7.25, dz - 0.35), (x, 6.2, dz - 0.35), 0.08)
        ellipsoid(lamp, (x, 5.75, dz - 0.35), (0.4, 0.5, 0.4), rings=4, segments=6)
    # Four round windows (sides and back).
    for deg in (-50.0, -130.0, 30.0, 150.0):
        a = math.radians(deg)
        n = (math.cos(a), 0.0, math.sin(a))
        _round_window(glass, posts, (n[0] * (r + 0.02), 5.4, n[2] * (r + 0.02)), n, 1.25)
    # Stone chimney through the roof (right-back) with a cartoon steam puff cluster on top.
    cx, cz = -5.2, 3.6
    cylinder(chimney, (cx, 9.0, cz), (cx, 19.4, cz), 1.05, segments=8, radius_b=0.9)
    revolve(chimney, [(0.75, 19.2), (1.3, 19.2), (1.3, 19.9), (0.75, 19.9)], center=(cx, 0, cz), segments=8, closed=True)
    for dx, dy, dz2, rr in ((0.0, 21.0, 0.0, 0.9), (0.6, 21.9, 0.3, 0.7), (-0.4, 22.5, -0.2, 0.55)):
        ellipsoid(steam, (cx + dx, dy, cz + dz2), (rr, rr * 0.85, rr), rings=4, segments=7)
    return m


# ------------------------------------------------------------------------------------------------
# D5 props
# ------------------------------------------------------------------------------------------------


def build_amber_jars():
    """
    Amber Jars: a two-shelf log rack with six glass jars of glowing amber (each with a tiny leaf
    inside), cork lids, a big amber crystal on top and a double-sided "AMBER" plank sign.
    """
    m = Model("D5_AmberJars", "ground centre; shelf faces -Z (front z = -0.9)", budget=2500)
    wood = m.piece("Shelf", LOG)
    wood2 = m.piece("Planks", LOG_LIGHT)
    jars = m.piece("Jars", (255, 236, 196), material="Glass", transparency=0.45)
    amber = m.piece("Amber", AMBER_LIGHT, material="Smooth")
    leaves = m.piece("Leaves", FERN_DARK, material="StudsSmall")
    lids = m.piece("Lids", LOG_DARK, material="StudsSmall")
    gem = m.piece("Gem", AMBER, material="Smooth")
    letters = m.piece("Letters", LOG_DARK, material="Smooth")
    w, d = 6.4, 1.8
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(wood, (sx * (w / 2 - 0.3), 2.9, sz * (d / 2 - 0.3)), (0.6, 5.8, 0.6), bevel=0.12)
    for y in (0.6, 2.95, 5.35):
        block(wood2, (0, y, 0), (w - 0.2, 0.3, d - 0.1), bevel=0.08)
    for row, y in enumerate((0.75, 3.1)):
        for k, x in enumerate((-1.9, 0.0, 1.9)):
            cylinder(jars, (x, y, 0), (x, y + 1.6, 0), 0.62, segments=10)
            cylinder(lids, (x, y + 1.6, 0), (x, y + 1.85, 0), 0.5, segments=10)
            boulder(amber, (x, y + 0.75, 0), (0.42, 0.5, 0.4), seed=row * 3 + k, rings=4, segments=6)
            leaf(leaves, (x - 0.12, y + 0.62, -0.02), 30.0 + 40 * k, 30.0, 0.5, 0.3, thick=0.05)
    # Big amber crystal on the top shelf + the AMBER sign standing beside it.
    cylinder(gem, (1.6, 5.5, 0), (1.6, 7.0, 0), 0.75, segments=6, radius_b=0.85)
    cylinder(gem, (1.6, 7.0, 0), (1.6, 8.1, 0), 0.85, segments=6, radius_b=0.05)
    block(wood2, (-1.2, 6.6, 0), (3.7, 1.2, 0.3), bevel=0.08)
    bar(wood, (-1.2, 5.5, 0), (-1.2, 6.05, 0), 0.25)
    text_both_at(letters, "AMBER", -1.2, 6.6, -0.15, 0.15, 0.11, 0.1)
    return m


def build_microscope():
    """
    Giant cartoon microscope on a round stone platform: cream body, teal accents, gold knobs, a C-arm
    seen side-on from the road, a stage holding a glass slide with an amber sample, a soft Lamp
    under the stage and a wooden ladder up to the eyepiece.
    """
    m = Model("D5_Microscope", "ground centre of the platform; profile faces -Z; Lamp under the stage", budget=3000)
    stone = m.piece("Platform", STONE_WARM)
    body = m.piece("Body", WHITE)
    teal = m.piece("Accent", (40, 156, 150))
    gold = m.piece("Knobs", GOLD, material="StudsSmall")
    slide = m.piece("Slide", (200, 236, 255), material="Glass", transparency=0.3)
    sample = m.piece("Sample", AMBER, material="Smooth")
    lamp = m.piece("Lamp", AMBER_LIGHT, material="Neon")
    wood = m.piece("Ladder", LOG)
    disc(stone, (0, 0, 0), 4.4, 0.6, segments=16, bevel=0.15)
    # Foot + C-arm (+X side) + stage + turret + tilted tube + eyepiece.
    block(teal, (0.4, 1.2, 0), (6.4, 1.2, 3.8), bevel=0.4)
    arm = [(2.5, 1.6, 0), (2.8, 3.6, 0), (2.85, 5.8, 0), (2.4, 7.8, 0), (1.3, 9.0, 0)]
    tube(body, arm, 0.75, sides=8)
    block(body, (-0.4, 4.6, 0), (4.2, 0.45, 3.6), bevel=0.15)
    bar(body, (2.5, 4.6, 0), (0.5, 4.6, 0), 0.9)
    for sz in (-1, 1):
        bar(teal, (-1.6, 4.86, sz * 1.0), (-0.1, 4.86, sz * 1.0), 0.14)
    block(slide, (-0.6, 4.92, 0), (2.6, 0.1, 1.3), bevel=0.0)
    boulder(sample, (-0.6, 5.06, 0), (0.45, 0.16, 0.35), seed=4, rings=3, segments=6)
    ellipsoid(lamp, (-0.6, 3.6, 0), (0.6, 0.35, 0.6), rings=4, segments=8)
    cylinder(teal, (-0.6, 3.15, 0), (-0.6, 3.5, 0), 0.75, segments=10)
    revolve(teal, [(0.0, 6.0), (1.25, 6.0), (1.25, 6.7), (0.0, 6.9)], center=(-0.6, 0, 0), segments=12)
    for a in (0, 120, 240):
        ox, oz = 0.6 * math.cos(math.radians(a)), 0.6 * math.sin(math.radians(a))
        cylinder(gold, (-0.6 + ox, 6.05, oz), (-0.6 + ox * 1.3, 5.35, oz * 1.3), 0.28, segments=6, radius_b=0.2)
    top = Vector((-2.4, 10.4, 0))
    cylinder(body, (-0.6, 6.7, 0), tuple(top), 0.95, segments=12)
    cylinder(teal, tuple(top), tuple(top + Vector((-0.45, 1.0, 0))), 0.62, segments=10)
    revolve(gold, [(0.5, -0.12), (0.72, -0.12), (0.72, 0.12), (0.5, 0.12)], center=tuple(top + Vector((-0.5, 1.12, 0))), segments=10, closed=True, rot=rot_z(24))
    bar(body, (1.3, 9.0, 0), (-1.2, 8.6, 0), 0.9)
    for sz in (-1, 1):
        cylinder(gold, (2.65, 5.0, sz * 0.7), (2.65, 5.0, sz * 1.35), 0.75, segments=10)
    # Ladder up the -X side to the eyepiece (wood, its feet on the platform).
    ladder(wood, (-4.0, 0.6, 0), 10.2, width=1.6, rung_step=1.0, rail=0.2, facing="x")
    return m


def build_incubators():
    """
    Egg Incubators: a bamboo table holding three straw nests with three big speckled eggs (Wobble*
    pieces: the eggs jiggle once W10 adds the "Wobble" row), a bamboo heat-lamp arm with a soft Lamp
    over the middle nest and a little thermometer board.
    """
    m = Model("D5_Incubators", "ground centre; table faces -Z; Wobble* = eggs (bob as one group); Lamp = heat lamp", budget=3000)
    bamboo = m.piece("Bamboo", BAMBOO)
    slats = m.piece("Slats", LOG_LIGHT)
    straw = m.piece("Straw", THATCH)
    shells = (
        m.piece("WobbleEggMint", (178, 238, 196)),
        m.piece("WobbleEggCream", (255, 240, 200)),
        m.piece("WobbleEggSky", (176, 214, 255)),
    )
    spots = m.piece("WobbleSpots", (70, 150, 96), material="Smooth")
    spots2 = m.piece("WobbleSpotsAmber", (240, 140, 50), material="Smooth")
    shade = m.piece("Shade", CLAY)
    lamp = m.piece("Lamp", AMBER_LIGHT, material="Neon")
    board = m.piece("Board", LOG_DARK)
    red = m.piece("Thermo", TOY_RED, material="Smooth")
    w, d, h = 9.6, 3.6, 2.2
    for sx in (-1, 1):
        for sz in (-1, 1):
            cylinder(bamboo, (sx * (w / 2 - 0.4), 0, sz * (d / 2 - 0.4)), (sx * (w / 2 - 0.4), h, sz * (d / 2 - 0.4)), 0.28, segments=6)
    for k in range(5):
        block(slats, (0, h + 0.12, -d / 2 + d * (k + 0.5) / 5), (w, 0.24, d / 5 - 0.06), bevel=0.06)
    bar(bamboo, (-w / 2 + 0.4, 0.9, -d / 2 + 0.4), (w / 2 - 0.4, 0.9, -d / 2 + 0.4), 0.22)
    # Nests + eggs (one egg per nest; speckles alternate green / blue).
    for k, x in enumerate((-3.0, 0.0, 3.0)):
        y0 = h + 0.24
        revolve(straw, [(0.5, y0), (1.35, y0), (1.45, y0 + 0.55), (1.15, y0 + 0.62), (0.9, y0 + 0.3), (0.5, y0 + 0.2)], center=(x, 0, 0), segments=12, closed=True)
        er = 0.95 if k == 1 else 0.85
        ec = (x, y0 + 0.25 + er * 1.3, 0.0)
        egg(shells[k], ec, er)
        sp = spots if k != 1 else spots2
        for j in range(5):
            yaw = j * 72.0 + 20.0 * k
            pitch = -10.0 + 30.0 * _hash(j, k)
            p, n = surface(ec, (er, er * 1.3, er), yaw, pitch)
            oriented_ellipsoid(sp, tuple(p - n * 0.02), (0.18, 0.15, 0.05), normal=tuple(n), rings=3, segments=5)
    # Heat-lamp arm from the back-left table leg over the middle nest.
    bx, bz = w / 2 - 0.4, d / 2 - 0.4
    cylinder(bamboo, (bx, h, bz), (bx, 7.4, bz), 0.24, segments=6)
    cylinder(bamboo, (bx, 7.4, bz), (0.0, 7.4, 0.3), 0.2, segments=6)
    revolve(shade, [(0.25, 0.0), (1.1, -0.95), (0.95, -1.0), (0.12, -0.05)], center=(0, 7.35, 0.3), segments=10, closed=True)
    ellipsoid(lamp, (0, 6.55, 0.3), (0.38, 0.38, 0.38), rings=4, segments=6)
    # Thermometer board on the front-right leg.
    block(board, (-w / 2 + 0.4, 1.4, -d / 2 - 0.05), (0.9, 2.2, 0.12), bevel=0.04)
    block(red, (-w / 2 + 0.4, 1.2, -d / 2 - 0.13), (0.22, 1.3, 0.05), bevel=0.0)
    ellipsoid(red, (-w / 2 + 0.4, 0.55, -d / 2 - 0.14), (0.22, 0.22, 0.06), rings=3, segments=6)
    return m


def _ammonite(piece, center, radius, normal=(0, 1, 0), turns=2.2, steps=22):
    """Raised spiral ammonite relief (tube on a plane ⟂ normal), tapering toward the centre."""
    from models._critter_kit import frame

    s, u, n = frame(normal, up=(0, 0, -1) if abs(normal[1]) > 0.9 else (0, 1, 0))
    c = Vector(center)
    pts, radii = [], []
    for i in range(steps + 1):
        t = i / steps
        a = t * turns * 2 * math.pi
        rr = radius * (0.12 + 0.88 * t)
        pts.append(tuple(c + s * (rr * math.cos(a)) + u * (rr * math.sin(a)) + n * 0.08))
        radii.append(0.05 + 0.14 * t)
    tube(piece, pts, 0.1, sides=5, radii=radii)


def build_dusting_brushes():
    """
    Dusting Brushes: a log work table with a fossil slab (raised ammonite + a little fish fossil), a
    clay pot of brushes, a hammer and chisel, and one giant dusting brush leaning on the table.
    """
    m = Model("D5_DustingBrushes", "ground centre; table faces -Z", budget=2500)
    wood = m.piece("Table", LOG)
    top = m.piece("TableTop", LOG_LIGHT)
    slab = m.piece("Slab", STONE_LIGHT)
    fossil = m.piece("Fossil", BONE_SHADE)
    pot = m.piece("Pot", CLAY)
    handles = m.piece("Handles", LOG_DARK)
    bristles = m.piece("Bristles", THATCH, material="StudsSmall")
    steel = m.piece("Tools", STEEL, material="StudsSmall")
    w, d, h = 6.4, 3.2, 2.6
    for sx in (-1, 1):
        for sz in (-1, 1):
            cylinder(wood, (sx * (w / 2 - 0.45), 0, sz * (d / 2 - 0.4)), (sx * (w / 2 - 0.45), h - 0.2, sz * (d / 2 - 0.4)), 0.3, segments=6)
    block(top, (0, h - 0.05, 0), (w, 0.3, d), bevel=0.1)
    # Fossil slab (tilted toward the road) with an ammonite and a fish skeleton.
    tilt = rot_x(-14)
    sc = Vector((-0.8, h + 0.45, 0.1))
    block(slab, tuple(sc), (3.4, 0.4, 2.4), bevel=0.12, rot=tilt)
    nrm = tilt @ Vector((0, 1, 0))
    surf = sc + nrm * 0.2
    _ammonite(fossil, tuple(surf + tilt @ Vector((-0.6, 0, 0))), 0.75, normal=tuple(nrm))
    fx = surf + tilt @ Vector((0.85, 0.06, 0))
    bar(fossil, tuple(fx + tilt @ Vector((-0.1, 0, -0.75))), tuple(fx + tilt @ Vector((-0.1, 0, 0.75))), 0.12)
    for k in range(4):
        zz = -0.45 + 0.3 * k
        bar(fossil, tuple(fx + tilt @ Vector((-0.5, 0, zz))), tuple(fx + tilt @ Vector((0.3, 0, zz))), 0.08)
    # Brush pot (right) with three brushes.
    px, pz = 2.1, 0.3
    revolve(pot, [(0.0, h + 0.1), (0.55, h + 0.1), (0.75, h + 0.7), (0.62, h + 1.3), (0.7, h + 1.45), (0.0, h + 1.45)], center=(px, 0, pz), segments=10)
    for k, (dx, dz, lean) in enumerate(((-0.25, 0.0, -14), (0.2, 0.15, 10), (0.0, -0.2, 2))):
        r = rot_z(lean)
        b0 = Vector((px + dx, h + 1.2, pz + dz))
        b1 = b0 + r @ Vector((0, 1.3, 0))
        cylinder(handles, tuple(b0), tuple(b1), 0.09, segments=5)
        cylinder(bristles, tuple(b1), tuple(b1 + r @ Vector((0, 0.5, 0))), 0.2, segments=6, radius_b=0.24)
    # Hammer + chisel lying on the table front.
    bar(handles, (0.6, h + 0.2, -1.1), (1.9, h + 0.2, -1.1), 0.14)
    block(steel, (0.6, h + 0.25, -1.1), (0.4, 0.3, 0.6), bevel=0.05)
    bar(steel, (-2.6, h + 0.17, -1.15), (-1.6, h + 0.17, -1.15), 0.12)
    # Giant brush leaning on the table's +X end.
    g0 = Vector((w / 2 + 1.6, 0.1, -0.2))
    g1 = Vector((w / 2 + 0.35, 5.0, -0.2))
    cylinder(handles, tuple(g0), tuple(g1), 0.22, segments=6)
    gd = (g1 - g0).normalized()
    cylinder(wood, tuple(g1 - gd * 0.1), tuple(g1 + gd * 0.5), 0.36, segments=8)
    cylinder(bristles, tuple(g1 + gd * 0.5), tuple(g1 + gd * 1.7), 0.42, segments=8, radius_b=0.6)
    return m


def build_skeleton():
    """
    HERO — the Big Skeleton: a giant friendly long-neck skeleton on a stone museum plinth, seen
    side-on from the road (head toward -X, raised high on its neck). Cream bones: a tapering spine
    tube with vertebra knobs and back spines, seven pairs of arched ribs, pelvis + shoulder-blade
    plates, four legs with knee / ankle knobs and toe bones, a rounded smiling skull with big round
    eye sockets (white shines, so it reads cute, not spooky). Dark support posts hold it up; a gold
    velvet-rope barrier and an info plaque stand in front.
    """
    m = Model(
        "D5_Skeleton",
        "ground centre of the plinth (layout: slot (31, 0.5, 55)); long axis X, head toward -X at y ~21; faces -Z",
        budget=6000,
    )
    plinth = m.piece("Plinth", STONE_LIGHT)
    trim = m.piece("PlinthTrim", STONE_DARK)
    bones = m.piece("Bones", BONE)
    knobs = m.piece("Knobs", BONE_SHADE)
    posts = m.piece("Supports", LOG_DARK)
    dark = m.piece("Sockets", EYE, material="Smooth")
    shine = m.piece("Shine", SHINE, material="Smooth")
    gold = m.piece("Brass", GOLD, material="StudsSmall")
    velvet = m.piece("Velvet", (196, 54, 70), material="StudsSmall")
    plaque = m.piece("Plaque", LOG_LIGHT)
    pw, pd, ph = 27.0, 8.0, 1.2
    block(plinth, (0, ph / 2, 0), (pw, ph, pd), bevel=0.25)
    top_slab = m.piece("PlinthTop", (238, 226, 204))
    block(trim, (0, ph - 0.25, 0), (pw + 0.12, 0.4, pd + 0.12), bevel=0.08)
    block(top_slab, (0, ph + 0.08, 0), (pw - 0.8, 0.16, pd - 0.8), bevel=0.05)
    top = ph + 0.16
    # Spine centreline (z = 0): tail tip (+X) -> hips -> back -> shoulders -> neck -> skull.
    spine = [
        (14.2, 2.4), (12.0, 3.6), (9.4, 5.6), (6.7, 7.7), (4.0, 9.1), (1.0, 9.6), (-2.2, 9.7),
        (-5.2, 9.9), (-7.6, 11.6), (-9.6, 14.2), (-11.0, 16.8), (-12.0, 19.2), (-12.6, 20.6),
    ]
    rad = [0.3, 0.42, 0.55, 0.66, 0.78, 0.82, 0.82, 0.8, 0.7, 0.62, 0.56, 0.5, 0.46]
    tube(bones, [(x, y + top - 1.36, 0) for x, y in spine], 0.5, sides=7, radii=rad)
    # Vertebra knobs along the spine + upright back spines over the body.
    for i in range(len(spine) - 1):
        (x0, y0), (x1, y1) = spine[i], spine[i + 1]
        for t in (0.0, 0.5):
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t + top - 1.36
            r = rad[i] * 1.35
            ellipsoid(knobs, (x, y, 0), (r * 0.55, r, r), rings=4, segments=6)
            if -6.0 < x < 7.0:
                bar(bones, (x, y + r * 0.6, 0), (x + 0.15, y + r + 0.75, 0), 0.22)
    # Ribs: seven pairs hanging from the back between the shoulders and hips.
    for k in range(7):
        x = -4.6 + k * 1.35
        ys = 9.75 + top - 1.36
        depth = 4.6 - abs(k - 3) * 0.45
        for sz in (-1, 1):
            path = [(x, ys - 0.2, sz * 0.4), (x + 0.15, ys - 0.9, sz * 2.0), (x + 0.35, ys - depth * 0.55, sz * 2.55), (x + 0.55, ys - depth, sz * 1.6)]
            tube(bones, path, 0.24, sides=5)
    # Pelvis + shoulder-blade plates (both sides).
    for sz in (-1, 1):
        oriented_ellipsoid(knobs, (4.0, 8.0 + top - 1.36, sz * 0.95), (1.8, 1.3, 0.3), normal=(0, 0, sz), rings=4, segments=8)
        oriented_ellipsoid(knobs, (-5.4, 8.4 + top - 1.36, sz * 1.9), (1.0, 1.6, 0.25), normal=(0, 0, sz), rings=4, segments=8)
    # Legs: femur + shin + knee / ankle knobs + three toe bones, all four standing on the plinth.
    for hx, hy, kx, fx in ((4.0, 7.6, 4.7, 3.9), (-5.3, 8.0, -4.6, -5.6)):
        for sz in (-1, 1):
            z = sz * 1.45
            hip = (hx, hy + top - 1.36, z)
            knee = (kx, 4.4 + top - 1.36, z)
            ankle = (fx, top + 0.7, z)
            cylinder(bones, hip, knee, 0.58, segments=7, radius_b=0.46)
            cylinder(bones, knee, ankle, 0.46, segments=7, radius_b=0.4)
            ellipsoid(knobs, knee, (0.72, 0.72, 0.72), rings=4, segments=6)
            ellipsoid(knobs, ankle, (0.58, 0.5, 0.58), rings=4, segments=6)
            for dz in (-0.35, 0.0, 0.35):
                bar(bones, (fx, top + 0.28, z + dz), (fx - 1.1, top + 0.22, z + dz * 1.4), 0.32)
    # Skull: rounded cranium + snout + lower jaw, big round sockets with shines, a smile line.
    sk = Vector((-14.0, 21.2 + top - 1.36, 0))
    ellipsoid(bones, tuple(sk), (2.0, 1.6, 1.55), rings=6, segments=10)
    ellipsoid(bones, tuple(sk + Vector((-1.95, -0.45, 0))), (1.6, 1.0, 1.2), rings=5, segments=8)
    bar(bones, tuple(sk + Vector((0.5, -1.25, 0))), tuple(sk + Vector((-2.9, -1.3, 0))), 0.5)
    for sz in (-1, 1):
        c = sk + Vector((-0.45, 0.32, sz * 1.36))
        oriented_ellipsoid(dark, tuple(c), (0.62, 0.7, 0.16), normal=(0, 0, sz), rings=4, segments=8)
        oriented_ellipsoid(shine, tuple(c + Vector((0.15, 0.26, sz * 0.14))), (0.2, 0.2, 0.05), normal=(0, 0, sz), rings=3, segments=5)
        smile_pts = [tuple(sk + Vector((-3.1 + 0.58 * i, -0.8 - 0.16 * math.sin(i * math.pi / 4), sz * 1.03))) for i in range(5)]
        tube(dark, smile_pts, 0.08, sides=4)
    # Dark support posts from the plinth to the spine (hips, mid-back, shoulders, neck).
    for x, y in ((4.0, 8.4), (-0.6, 9.0), (-5.0, 9.2), (-9.4, 13.4)):
        cylinder(posts, (x, top, 0), (x, y + top - 1.36, 0), 0.18, segments=5)
    block(posts, (-9.4, top + 0.15, 0), (1.2, 0.3, 1.2), bevel=0.05)
    # Velvet rope barrier in front + an info plaque on a slanted stand.
    rz = -pd / 2 - 1.4
    xs = (-11.0, -3.5, 4.0, 11.5)
    for x in xs:
        cylinder(gold, (x, 0, rz), (x, 2.4, rz), 0.16, segments=6)
        ellipsoid(gold, (x, 2.55, rz), (0.26, 0.26, 0.26), rings=3, segments=6)
        disc(gold, (x, 0, rz), 0.5, 0.18, segments=8, bevel=0.04)
    for a, b in zip(xs, xs[1:]):
        cable(velvet, (a + 0.2, 2.3, rz), (b - 0.2, 2.3, rz), 0.5, thick=0.14, steps=6)
    bar(posts, (7.6, 0, rz + 0.3), (7.6, 1.6, rz + 0.3), 0.18)
    block(plaque, (7.6, 1.75, rz + 0.3), (2.2, 1.3, 0.16), bevel=0.04, rot=rot_x(-30))
    bone_shape(knobs, (6.95, 1.72, rz + 0.18), (8.25, 1.72, rz + 0.18), 0.12, knob=0.17, segments=5)
    return m


def build_dig_site():
    """
    Dig Site: a rectangular sand berm round a dark dirt pit with a string grid on stakes, a half-buried
    giant bone and a vertebra, a shovel stuck in the berm, a red bucket and a double-sided "DIG" sign.
    """
    m = Model("D5_DigSite", "ground centre of the pit (13 x 9); sign faces -Z", budget=3000)
    berm = m.piece("Berm", SAND_DARK)
    dirt = m.piece("Dirt", DIRT)
    stakes = m.piece("Stakes", LOG)
    rope = m.piece("Strings", ROPE, material="StudsSmall")
    bone = m.piece("Bone", BONE)
    steel = m.piece("Shovel", STEEL, material="StudsSmall")
    bucket = m.piece("Bucket", TOY_RED)
    sign = m.piece("Sign", LOG_LIGHT)
    letters = m.piece("Letters", LOG_DARK, material="Smooth")
    w, d = 13.0, 9.0
    block(dirt, (0, 0.06, 0), (w - 0.4, 0.12, d - 0.4), bevel=0.0)
    for sx in (-1, 1):
        block(berm, (sx * (w / 2 - 0.6), 0.45, 0), (1.6, 0.9, d + 1.0), bevel=0.4)
    for sz in (-1, 1):
        block(berm, (0, 0.42, sz * (d / 2 - 0.6)), (w - 3.0, 0.84, 1.5), bevel=0.4)
    # Grid stakes (corners + mid) and strings 0.55 above the dirt.
    xs, zs = (-5.0, -1.65, 1.65, 5.0), (-3.4, 0.0, 3.4)
    for x in (xs[0], xs[-1]):
        for z in zs:
            cylinder(stakes, (x, 0.05, z), (x, 1.6, z), 0.12, segments=5)
    for z in (zs[0], zs[-1]):
        for x in xs[1:-1]:
            cylinder(stakes, (x, 0.05, z), (x, 1.6, z), 0.12, segments=5)
    for z in zs:
        bar(rope, (xs[0], 1.4, z), (xs[-1], 1.4, z), 0.06)
    for x in xs[1:-1]:
        bar(rope, (x, 1.4, zs[0]), (x, 1.4, zs[-1]), 0.06)
    # Half-buried finds: a big bone poking out at an angle + a round vertebra + a small rib.
    bone_shape(bone, (-3.8, 0.85, 1.4), (-0.3, 1.2, 2.2), 0.42, knob=0.6, segments=8)  # lowest knob ~0.1 into the lot
    ellipsoid(bone, (2.6, 0.3, -1.2), (0.8, 0.45, 0.8), rings=4, segments=8)
    tube(bone, [(1.4, 0.1, 1.8), (2.4, 0.6, 2.2), (3.4, 0.35, 2.9)], 0.18, sides=5)
    # Shovel stuck in the right berm, red bucket on the left berm.
    s0 = Vector((w / 2 - 0.6, 0.5, -2.6))
    s1 = s0 + Vector((0.5, 3.6, 0.3))
    cylinder(stakes, tuple(s0), tuple(s1), 0.13, segments=5)
    bar(stakes, tuple(s1 + Vector((-0.35, 0, 0))), tuple(s1 + Vector((0.35, 0, 0))), 0.16)
    block(steel, tuple(s0 + Vector((-0.05, -0.15, 0))), (0.9, 1.0, 0.12), bevel=0.04, rot=rot_z(-8))
    revolve(bucket, [(0.0, 0.9), (0.5, 0.9), (0.68, 1.85), (0.0, 1.85)], center=(-w / 2 + 0.6, 0, 2.2), segments=10)
    # "DIG" sign on a stake at the front-left corner.
    cylinder(stakes, (-w / 2 + 1.2, 0, -d / 2 - 0.6), (-w / 2 + 1.2, 3.2, -d / 2 - 0.6), 0.16, segments=5)
    block(sign, (-w / 2 + 1.2, 3.3, -d / 2 - 0.6), (2.4, 1.1, 0.24), bevel=0.06)
    # text_both mirrors z for the back copy, so the sign must be centred on z = 0 in the call frame:
    # draw at z 0 and move the letters with the sign (x and z).
    place_new([letters], lambda: text_both(letters, "DIG", 3.3, -0.12, 0.12, 0.12, 0.08), Xf((-w / 2 + 1.2, 0.0, -d / 2 - 0.6)))
    return m


def build_dr_trike():
    """
    Dr. Trike (Manager): a sky-blue triceratops scientist on W6's shared Dino body (dino_biped) in a
    white lab coat (cream shirt front, lapels), lab goggles pushed up under the frill, holding a
    magnifying glass up in the right hand, beside a small specimen desk with a bone in a glass jar.
    Figure at the model origin, yaw 0 (like every Dino manager). R30 rig: rest pose = left arm
    relaxed (the wave arm); the magnifier rides ArmR; face / shine / goggles ride the Head.
    """
    from models._npc_rig import rig_split

    m = Model("D5_DrTrike", "ground centre between the feet; Dr. Trike faces -Z; specimen desk at local +X", budget=3000)
    mat = m.piece("Mat", LOG_LIGHT)
    skin = m.piece("Skin", TRIKE, material="Smooth")
    tail = m.piece("Tail", TRIKE, material="Smooth")
    belly = m.piece("Belly", (238, 246, 214), material="Smooth")
    face = m.piece("Face", EYE, material="Smooth")
    shine = m.piece("Shine", SHINE, material="Smooth")
    horns = m.piece("Horns", BONE, material="Smooth")
    frill = m.piece("Frill", TRIKE_FRILL, material="Smooth")
    coat = m.piece("Coat", WHITE)
    lens = m.piece("Goggles", SKY_BLUE, material="Smooth")
    gold = m.piece("Magnifier", GOLD, material="StudsSmall")
    glass = m.piece("MagnifierGlass", (200, 236, 255), material="Glass", transparency=0.35)
    desk = m.piece("Desk", LOG)
    jar = m.piece("Jar", (220, 240, 255), material="Glass", transparency=0.45)
    bone = m.piece("Specimen", BONE)
    block(mat, (1.8, 0.06, 0), (7.2, 0.12, 4.2), bevel=0.04)  # thin: the feet stand at y 0, toes show
    a = dino_biped(
        {"skin": skin, "belly": belly, "face": face, "shine": shine, "tail": tail},
        body=(1.35, 1.55, 1.25),
        head=(1.1, 0.98, 1.05),
        snout=0.72,
        arm_pose={"left": (12.0, 25.0), "right": (6.0, 135.0)},
    )
    body_shell(coat, belly, a, lapel=belly)
    trike_head(frill, horns, a)
    goggles(face, lens, a)
    # Magnifier in the right hand: handle up from the hand, ring + glass above it, facing -Z.
    hx, hy, hz = a["hands"]["right"]
    cylinder(gold, (hx, hy - 0.2, hz), (hx, hy + 0.6, hz), 0.11, segments=5)
    ring = (hx, hy + 1.2, hz - 0.1)
    revolve(gold, [(0.55, -0.08), (0.72, -0.08), (0.72, 0.08), (0.55, 0.08)], center=ring, segments=12, closed=True, rot=rot_x(90))
    oriented_ellipsoid(glass, ring, (0.58, 0.58, 0.05), normal=(0, 0, -1), rings=3, segments=10)
    # Specimen desk at local +X: four legs, top, a jar with a little bone inside.
    tx = 3.9
    for sx in (-1, 1):
        for sz in (-1, 1):
            cylinder(desk, (tx + sx * 0.9, 0.2, sz * 0.75), (tx + sx * 0.9, 2.5, sz * 0.75), 0.16, segments=5)
    block(desk, (tx, 2.6, 0), (2.4, 0.24, 2.0), bevel=0.06)
    cylinder(jar, (tx + 0.2, 2.72, 0.1), (tx + 0.2, 4.0, 0.1), 0.5, segments=10)
    bone_shape(bone, (tx + 0.2, 2.95, 0.1), (tx + 0.2, 3.7, 0.1), 0.08, knob=0.13, segments=5)
    rig_split(
        m,
        dino_bones(a),
        static=("Mat", "Desk", "Jar", "Specimen"),
        assign={
            "Tail": "Torso", "Coat": "Torso", "Frill": "Head", "Horns": "Head", "Goggles": "Head", "Face": "Head",
            "Shine": "Head",
            "Magnifier": "ArmR", "MagnifierGlass": "ArmR",
        },
    )
    return m


def build_museum_banners():
    """
    Museum Banners: two log poles flanking the walkway, each with a crossbar, a bone finial and a
    tall double-sided cloth banner (amber with a bone emblem / fern green with an egg emblem), plus a
    sagging bunting string between the pole tops (Pennant* pieces sway: existing WorldFx row).
    """
    m = Model("D5_MuseumBanners", "ground centre of the walkway; poles at x = +-9; banners face -Z; Pennant* sway", budget=2500)
    wood = m.piece("Poles", LOG)
    finial = m.piece("Finials", BONE)
    cloth = m.piece("BannerAmber", AMBER)
    cloth2 = m.piece("BannerFern", FERN)
    emblem = m.piece("Emblems", BONE, material="Smooth")
    spots = m.piece("EggSpots", FERN_DARK, material="Smooth")
    rope = m.piece("PennantRope", ROPE, material="StudsSmall")
    flags_a = m.piece("PennantAmber", AMBER_LIGHT, material="StudsSmall")
    flags_b = m.piece("PennantFern", MOSS, material="StudsSmall")
    flags_c = m.piece("PennantBone", BONE, material="StudsSmall")
    px, ph = 9.0, 15.0
    for sx in (-1, 1):
        x = sx * px
        disc(wood, (x, 0, 0), 0.75, 0.4, segments=8, bevel=0.1)
        cylinder(wood, (x, 0.3, 0), (x, ph, 0), 0.34, segments=8)
        bar(wood, (x, ph - 0.9, 0), (x + sx * 3.6, ph - 0.9, 0), 0.3)
        bone_shape(finial, (x - 0.6, ph + 0.45, 0), (x + 0.6, ph + 0.45, 0), 0.2, knob=0.3, segments=6)
        # Banner: hangs from the crossbar on the outer side, swallow-tail bottom, both faces lettered
        # with the same emblem (bone on the amber one, egg on the fern one).
        bx = x + sx * 2.0
        top, bottom = ph - 1.2, ph - 8.6
        outline = [(bx - 1.5, top), (bx + 1.5, top), (bx + 1.5, bottom), (bx, bottom + 0.9), (bx - 1.5, bottom)]
        prism(cloth if sx > 0 else cloth2, [(x_, y_, 0.0) for x_, y_ in outline], (0, 0, 1), 0.2)
        cy = (top + bottom) / 2 + 0.6
        for sz in (-1, 1):
            if sx > 0:
                bone_shape(emblem, (bx - 0.75, cy - 0.75, sz * 0.16), (bx + 0.75, cy + 0.75, sz * 0.16), 0.17, knob=0.26, segments=6)
            else:
                ec = (bx, cy, sz * 0.13)
                oriented_ellipsoid(emblem, ec, (0.85, 1.1, 0.06), normal=(0, 0, sz), rings=4, segments=10)
                for dx, dy in ((-0.3, 0.35), (0.35, 0.05), (-0.15, -0.45)):
                    oriented_ellipsoid(spots, (bx + dx, cy + dy, sz * 0.2), (0.17, 0.14, 0.03), normal=(0, 0, sz), rings=3, segments=5)
    # Bunting: rope between the pole tops sagging over the walkway; 9 triangle flags in three colours.
    a, b = Vector((-px + 0.35, ph - 0.4, 0)), Vector((px - 0.35, ph - 0.4, 0))
    cable(rope, tuple(a), tuple(b), 1.4, thick=0.09, steps=8)
    flags = (flags_a, flags_b, flags_c)
    for k in range(9):
        t = (k + 1) / 10
        p = a.lerp(b, t)
        p.y -= 1.4 * 4 * t * (1 - t)
        tri = [(p.x - 0.55, p.y - 0.05, 0.0), (p.x + 0.55, p.y - 0.05, 0.0), (p.x, p.y - 1.2, 0.0)]
        prism(flags[k % 3], tri, (0, 0, 1), 0.08)
    return m


BUILDERS = {
    "D5_Floor": build_floor,
    "D5_EntryArch": build_entry_arch,
    "D5_LabHut": build_lab_hut,
    "D5_AmberJars": build_amber_jars,
    "D5_Microscope": build_microscope,
    "D5_Incubators": build_incubators,
    "D5_DustingBrushes": build_dusting_brushes,
    "D5_Skeleton": build_skeleton,
    "D5_DigSite": build_dig_site,
    "D5_DrTrike": build_dr_trike,
    "D5_MuseumBanners": build_museum_banners,
}
