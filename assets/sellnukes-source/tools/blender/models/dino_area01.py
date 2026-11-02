"""
dino_area01.py — Dino Valley area D1 "Cave Workshop" models (W6 art-d12, owner R57) + the shared
Dino Valley art helpers used by every dino_areaNN.py builder (spec 2026-10-31-world2-design §2 / §16).

A mossy sandstone cliff with a cave mouth, flickering torches and a stone bench where a friendly
raptor chisels glowing "pebble nukes". Palette (spec §2): fern green / sand / mossy stone / amber
orange / bone cream / lava candy-orange; organic round shapes, logs, thatch, rope. No grey metal,
no hazard stripes.

    D1_Floor         jungle-floor lot: moss patches, a sandy path + clearing, stepping stones  base
    D1_EntryArch     "CAVE WORKSHOP" boulder-post arch, log-framed board, pebble-nuke finials  base
    D1_CaveCliff     mossy cliff across the back with a cave mouth, vines and ferns (<= 6k)    base
    D1_Jungle        palms, ferns and boulders framing the lot (split L / R, owner R31)       base
    D1_StoneBench    the producer: boulder-legged slab bench, a hovering glowing pebble nuke,  D1_StoneBench
                     chisel + mallet and a pebble pile
    D1_TorchWall     dry-stone wall segment with three torches (placed 2x)                     D1_TorchWall
    D1_BoneTools     log rack of cartoon bone tools + a tool stump                             D1_BoneTools
    D1_CavePaintings standing painted rock: original dino doodles, a sun and a pebble nuke     D1_CavePaintings
    D1_FirePit       stone ring, log teepee, Neon flames + a steam (smoke) anchor              D1_FirePit
    D1_LeafBellows   giant-leaf accordion bellows on a log frame, bamboo nozzle               D1_LeafBellows
    D1_RockyRaptor   the Manager: a round orange raptor in a leather apron + cap, chisel in    D1_RockyRaptor
                     hand; split into the R30 rig groups (tail rides the Torso)
    D1_LogFence      16-stud log fence run with rope lashings (placed 4x)                      D1_LogFence

Placement: src/shared/Config/Worlds/Dino/Layouts/Area01.luau (slot-local frame, docs/areas-art.md).
SLOT-ORIGIN models (D1_Floor, D1_CaveCliff, D1_Jungle) use the slot origin as pivot (identity cf):
road-side edge midpoint at ground level, +Z away from the road, slot x in [-52, 52], z in [0, 70].
Every other model is pivoted at its own ground centre with its front toward -Z (the road).

WorldFx piece names (the client animates by the leading word; docs in WorldFxConfig):
    Flame*       torch / fire flames: small Neon (R19-safe) — needs a `Flame` row (soft flicker light)
    SteamAnchor  invisible emitter anchor above the fire pit — resolves to the existing `Steam` row
    Nuke*        the bench's pebble nuke hovers as ONE group (existing `Nuke` bob row, R25)
Manager rig (R30): D1_RockyRaptor pieces are Torso* / Head* / ArmL* / ArmR* / LegL* / LegR*.

Shared helpers exported for dino_area02..06.py (import from models.dino_area01):
    palette constants (FERN, MOSS, SAND, STONE, AMBER, BONE, LAVA, LOG, BARK, THATCH, BAMBOO, ...)
    boulder(piece, center, radii, seed)          lumpy low-poly rock (deterministic)
    fern(piece, base, size, seed)                 arching fern fronds
    palm(trunk, leaves, base, height, seed)       curved palm with drooping leaves
    log(piece, a, b, radius)                      round log between two points
    bone(piece, a, b, radius)                     cartoon dog-bone (spec §2 "Bones")
    pebble_nuke(stone, band, fins, base, height)  the Dino-world product: a rounded stone nuke
    dino_arch(key, lines, ...)                    themed entry arch, double-sided letters (R17)
    dino_biped(parts, ...) / dino_bones(anchors)  chunky cartoon biped dino + its R30 skeleton

Budgets (docs/world-art.md §4; spec §15: a fully built Dino area <= 28k triangles): lots <= 2,000,
backdrops <= 6,000, arches <= 4,500, machines / managers <= 3,000, small props <= 1,500.
Z-fight layers (docs/areas-art.md R18): lot top y = 0.5 (LOT_TOP), sand path +0.06, moss patches
+0.1, stepping stones +0.18.
"""

from __future__ import annotations

import math

from mathutils import Vector

from models._critter_kit import eyes, oriented_ellipsoid, plate, smile, tube
from models.area01 import LOT_TOP, SLOT_PIVOT, sign_text, text_cells
from models.area04 import _hash
from snkit.core import Model
from snkit.kit import block, disc
from snkit.shapes import box, cylinder, ellipsoid, extrude_outline, loft, prism, revolve, rot_x, rot_y, rot_z

# ------------------------------------------------------------------------------------------------
# Dino Valley palette (spec §2). RGB 0..255; the stud map darkens these ~10 % on screen.
# ------------------------------------------------------------------------------------------------

FERN = (86, 178, 74)  # leaves, fronds
FERN_DARK = (58, 140, 60)  # second leaf tone
JUNGLE_FLOOR = (104, 170, 70)  # lot ground
MOSS = (140, 204, 84)  # moss caps / patches
SAND = (238, 212, 152)  # paths, tablets
SAND_DARK = (210, 176, 116)
STONE = (196, 176, 138)  # warm mossy sandstone
STONE_DARK = (156, 138, 110)
STONE_WARM = (196, 172, 128)
AMBER = (255, 168, 40)
AMBER_GLOW = (255, 196, 90)  # small Neon accents only (R19)
BONE = (250, 236, 200)  # cartoon bones, letters
LAVA = (255, 120, 50)  # candy-orange "warm jelly"
FLAME_YELLOW = (255, 220, 90)
LOG = (196, 132, 74)
LOG_END = (236, 196, 136)  # cut log ends
BARK = (150, 98, 58)
THATCH = (230, 190, 104)
BAMBOO = (196, 206, 96)
CAVE_DARK = (60, 50, 46)
INK = (52, 40, 40)  # eyes, smiles

SLOT_W = 104.0
SLOT_D = 70.0


# ------------------------------------------------------------------------------------------------
# Shared organic helpers
# ------------------------------------------------------------------------------------------------


def boulder(piece, center, radii, seed=0, rings=4, segments=7, lump=0.16):
    """
    Lumpy low-poly rock: an ellipsoid whose vertices are pushed in/out by a deterministic hash
    (same seed -> same rock -> same piece hash, so a rebuild never re-uploads). ~42 triangles with
    the defaults. `center` is the ellipsoid centre (sink it a little into what it rests on).

    Example: boulder(rock, (4, 1.0, 12), (1.6, 1.2, 1.4), seed=7)
    """
    k = [0]

    def deform(x, y, z):
        k[0] += 1
        f = 1.0 + lump * (_hash(seed * 31 + k[0], 3.7) - 0.5) * 2.0
        # Flatten the underside so rocks sit on the ground instead of balancing on a point.
        if y < 0:
            y *= 0.75
        return (x * f, y * (0.92 + 0.08 * f), z * f)

    ellipsoid(piece, center, radii, rings=rings, segments=segments, deform=deform)


def fern(piece, base, size=1.0, seed=0, fronds=6):
    """
    Arching fern: `fronds` leaf blades (thin 5-point plates) radiating from `base` and curving
    out and down. 16 triangles per frond. `size` = frond length scale (1.0 ~ 2.6 studs long).

    Example: fern(leaves, (10, 0.5, 30), size=1.2, seed=3)
    """
    bx, by, bz = base
    for i in range(fronds):
        a = 2 * math.pi * (i + _hash(seed, i) * 0.6) / fronds
        length = size * (2.2 + 0.8 * _hash(seed + 5, i))
        rise = size * (0.9 + 0.5 * _hash(seed + 9, i))
        width = size * 0.42
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        side = Vector((-d.z, 0.0, d.x))
        # Blade centre-line: up from the root, then out and drooping at the tip.
        p0 = Vector((bx, by + 0.05, bz))
        p1 = p0 + d * (length * 0.45) + Vector((0, rise, 0))
        p2 = p0 + d * length + Vector((0, rise * 0.45, 0))
        outline = [
            p0 + side * (width * 0.15),
            p1 + side * width,
            p2,
            p1 - side * width,
            p0 - side * (width * 0.15),
        ]
        # Thin blade: extrude along the blade's own normal (perpendicular to side + direction).
        tangent = (p2 - p0).normalized()
        normal = side.cross(tangent).normalized()
        prism(piece, [tuple(p) for p in outline], tuple(normal), 0.08)


def palm(trunk, leaves, base, height=10.0, seed=0, lean=8.0, leaf_count=6, nuts=None):
    """
    Cartoon palm: a gently curving segmented trunk (6-sided, ringed look from slightly offset
    segments) and `leaf_count` drooping leaves (long plates) at the crown; optional coconuts.
    Returns the crown point. ~250 triangles with defaults.
    """
    bx, by, bz = base
    lean_dir = 2 * math.pi * _hash(seed, 1)
    lx, lz = math.cos(lean_dir), math.sin(lean_dir)
    segs = 5
    pts = []
    for i in range(segs + 1):
        t = i / segs
        off = math.sin(math.radians(lean)) * height * t * t
        pts.append((bx + lx * off, by + height * t, bz + lz * off))
    for i in range(segs):
        r0 = 0.62 - 0.22 * (i / segs)
        cylinder(trunk, pts[i], (pts[i + 1][0], pts[i + 1][1] + 0.12, pts[i + 1][2]), r0, segments=6, radius_b=r0 * 0.86)
    crown = pts[-1]
    cx, cy, cz = crown
    ellipsoid(leaves, (cx, cy + 0.2, cz), (0.75, 0.55, 0.75), rings=3, segments=6)
    for i in range(leaf_count):
        a = 2 * math.pi * (i + 0.3 * _hash(seed + 3, i)) / leaf_count
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        side = Vector((-d.z, 0.0, d.x))
        length = 4.2 + 1.0 * _hash(seed + 7, i)
        root = Vector((cx, cy + 0.3, cz))
        mid = root + d * (length * 0.5) + Vector((0, 0.8, 0))
        tip = root + d * length + Vector((0, -1.4, 0))
        w = 0.9
        outline = [root + side * 0.2, mid + side * w, tip, mid - side * w, root - side * 0.2]
        normal = side.cross((tip - root).normalized()).normalized()
        prism(leaves, [tuple(p) for p in outline], tuple(normal), 0.1)
    if nuts is not None:
        for i in range(3):
            a = 2 * math.pi * i / 3 + 0.5
            ellipsoid(nuts, (cx + 0.5 * math.cos(a), cy - 0.35, cz + 0.5 * math.sin(a)), (0.32, 0.32, 0.32), rings=4, segments=6)
    return crown


def log(piece, a, b, radius, segments=8, ends=None):
    """
    Round log from point a to b. `ends` (optional piece) gets slightly proud end-grain discs on
    both ends (+0.04 so they never share the log's cap plane, R18).
    """
    cylinder(piece, a, b, radius, segments=segments)
    if ends is not None:
        va, vb = Vector(a), Vector(b)
        d = (vb - va).normalized()
        for p, s in ((va, -1.0), (vb, 1.0)):
            c0 = p + d * (s * 0.0)
            c1 = p + d * (s * 0.05)
            cylinder(ends, tuple(c0 - d * (s * 0.02)), tuple(c1), radius * 0.82, segments=segments)


def bone(piece, a, b, radius, knob=None, segments=8):
    """
    Cartoon dog-bone (spec §2: "chunky dog-bone silhouette in cream"): a shaft from a to b with a
    pair of round knobs at each end, splayed sideways. ~170 triangles with the defaults.
    """
    va, vb = Vector(a), Vector(b)
    d = (vb - va).normalized()
    up = Vector((0, 1, 0)) if abs(d.y) < 0.9 else Vector((1, 0, 0))
    side = up.cross(d).normalized()
    k = knob if knob is not None else radius * 1.55
    cylinder(piece, a, b, radius, segments=segments)
    for p in (va, vb):
        for s in (-1, 1):
            c = p + side * (s * k * 0.62) - d * (0.0)
            ellipsoid(piece, tuple(c), (k, k, k), rings=4, segments=segments)


def pebble_nuke(stone, band, fins, base, height=2.4, radius=None, segments=10):
    """
    The Dino-world product (spec §2 "pebble nukes are carved from glowing stones"): a rounded egg
    of stone with a pointed stone nose, three stubby stone fins at the bottom and a glowing amber
    band round its middle (`band` should be a small Neon piece: its box stays under the R19 limit
    for heights <= ~3). Standing on `base` (bottom centre). Returns the band centre y.

    Example: pebble_nuke(stone, glow, fins, (0, 3.5, 0), height=2.4)
    """
    bx, by, bz = base
    r = radius if radius is not None else height * 0.33
    body_h = height * 0.72
    cy = by + body_h * 0.5 + 0.05
    ellipsoid(stone, (bx, cy, bz), (r, body_h * 0.5, r), rings=6, segments=segments)
    # Nose: a rounded cone continuing the egg upward.
    revolve(
        stone,
        [(r * 0.55, 0.0), (r * 0.36, height * 0.14), (r * 0.12, height * 0.24), (0.0, height * 0.27)],
        center=(bx, by + body_h * 0.82, bz),
        segments=segments,
    )
    # Fins: three stubby rounded slabs at 120 degrees (one points at the viewer, -Z).
    for i in range(3):
        a = math.radians(-90 + 120 * i)
        dx, dz = math.cos(a), math.sin(a)
        c = (bx + dx * r * 0.95, by + body_h * 0.2, bz + dz * r * 0.95)
        block(fins, c, (0.22, body_h * 0.42, r * 0.8), bevel=0.06, rot=rot_y(-math.degrees(a)))
    # Glow band: a short ring proud of the body by ~0.05.
    band_y = cy + body_h * 0.06
    revolve(
        band,
        [(r * 1.03, -height * 0.05), (r * 1.06, 0.0), (r * 1.03, height * 0.05)],
        center=(bx, band_y, bz),
        segments=segments,
        closed=True,
    )
    return band_y


def dino_arch(
    key,
    lines,
    *,
    inner=14.0,
    post_h=9.0,
    post_w=3.6,
    stone=STONE,
    stone_dark=STONE_DARK,
    moss=MOSS,
    board=LOG,
    frame=BARK,
    letters=BONE,
    leaves=FERN,
    cell=None,
    budget=4500,
    post_style="stone",
):
    """
    Dino Valley entry arch: two posts (post_style "stone": stacked boulders; "bamboo": a lashed
    bundle of three bamboo poles) with moss caps, a log-framed plank board carrying the area name in
    block letters on BOTH faces (owner R17), a big cartoon bone crest on top, pebble-nuke finials
    with small amber Neon bands (R19) and fern fronds draping at the corners. Every element is
    mirrored left/right and front/back, so the arch reads the same from the road and from inside.

    inner: clear width between the posts. Pivot: ground centre under the board, sign faces -Z.
    Returns the Model with `arch_info` (board_y, board_h, board_w, post_x, top_y).

    Example: dino_arch("D2_EntryArch", ["FERN", "MARKET"], board=THATCH, post_style="bamboo")
    """
    m = Model(key, "ground centre between the posts; sign faces -Z (the road), reads from both sides", budget=budget)
    posts = m.piece("Posts", stone)
    posts_dark = m.piece("PostsDark", stone_dark)
    cap = m.piece("Moss", moss)
    panel = m.piece("Panel", board)
    trim = m.piece("Frame", frame)
    text = m.piece("Letters", letters, material="Smooth")
    crest = m.piece("Crest", BONE, material="StudsSmall")
    leaf = m.piece("Leaves", leaves)
    px = inner / 2 + post_w / 2
    for sx in (-1, 1):
        if post_style == "bamboo":
            # Three bamboo poles in a triangle, ring joints every ~2.6 studs, two rope lashings.
            for k in range(3):
                a = math.radians(90 + 120 * k)
                x, z = sx * px + 0.72 * math.cos(a), 0.72 * math.sin(a)
                cylinder(posts, (x, 0.0, z), (x, post_h, z), 0.62, segments=8)
                for y in (2.6, 5.2, 7.8):
                    cylinder(posts_dark, (x, y - 0.12, z), (x, y + 0.12, z), 0.7, segments=8)
            for y in (1.6, 6.5):
                cylinder(posts_dark, (sx * px, y - 0.3, 0), (sx * px, y + 0.3, 0), 1.48, segments=10)
        else:
            # Three stacked rounded stones, alternating tones, each a bit smaller.
            y = 0.0
            tiers = ((post_w + 0.6, 3.4, posts_dark), (post_w, 3.2, posts), (post_w - 0.5, post_h - 6.6, posts_dark))
            for w, h, piece in tiers:
                block(piece, (sx * px, y + h / 2, 0), (w, h, w), bevel=0.5, segments=2)
                y += h - 0.02
        # Moss cap on top of the post (its own height, never flush with the post top, R18).
        block(cap, (sx * px, post_h + 0.25, 0), (post_w + 0.0, 0.6, post_w + 0.0), bevel=0.25, segments=2)
    lines = [lines] if isinstance(lines, str) else list(lines)
    board_w = inner + 2 * post_w + 1.2
    widest = max(text_cells(line) for line in lines)
    pad = 0.9
    if cell is None:
        cell = min(0.6, (board_w - 2 * pad - 1.0) / widest)
    rows = len(lines) * 7 + (len(lines) - 1) * 2
    board_h = rows * cell + 2 * pad
    board_y = post_h + 0.55 + board_h / 2
    depth = 1.0
    block(panel, (0, board_y, 0), (board_w - 0.4, board_h - 0.4, depth), bevel=0.12)
    # Log frame: top + bottom logs run past the board ends; short side logs stop inside them.
    lr = 0.42
    for sy in (-1, 1):
        y = board_y + sy * (board_h / 2)
        log(trim, (-board_w / 2 - 0.9, y, 0), (board_w / 2 + 0.9, y, 0), lr, segments=8)
    for sx in (-1, 1):
        x = sx * (board_w / 2)
        log(trim, (x, board_y - board_h / 2 + lr * 0.6, 0), (x, board_y + board_h / 2 - lr * 0.6, 0), lr * 0.9, segments=8)
    sign_text(text, lines, (0, board_y, 0), cell, 0.3, depth / 2)
    top_y = board_y + board_h / 2 + lr
    # Crest: a big cartoon bone lying along the top log.
    bone(crest, (-3.0, top_y + 0.45, 0), (3.0, top_y + 0.45, 0), 0.32, knob=0.5)
    # Finials: a pebble nuke standing on the top log above each post, with a small amber Neon band
    # (one piece per side so each band's box stays under the R19 Neon limit).
    for sx, side in ((-1, "L"), (1, "R")):
        band = m.piece(f"Band{side}", AMBER_GLOW, material="Neon")
        pebble_nuke(posts, band, posts_dark, (sx * px, top_y - 0.12, 0), height=2.8)
    # Fern fronds draping over the board corners, mirrored front / back.
    for sx in (-1, 1):
        for sz in (-1, 1):
            root = Vector((sx * (board_w / 2 - 0.4), board_y + board_h / 2 + 0.2, sz * 0.55))
            for i in range(3):
                a = math.radians(30 + 35 * i)
                d = Vector((-sx * math.cos(a) * 0.4, -math.sin(a), 0.0)).normalized()
                tip = root + d * 2.6 + Vector((0, 0, sz * 0.25))
                mid = root + d * 1.3 + Vector((0, 0, sz * 0.32))
                side = Vector((0, 0, 1)).cross(d).normalized()
                outline = [root + side * 0.15, mid + side * 0.45, tip, mid - side * 0.45, root - side * 0.15]
                prism(leaf, [tuple(p) for p in outline], (0, 0, sz), 0.08)
    m.arch_info = {"board_y": board_y, "board_h": board_h, "board_w": board_w, "post_x": px, "top_y": top_y}
    return m


def dino_biped(parts, *, body=(1.35, 1.55, 1.25), head=(1.05, 0.95, 1.0), snout=0.75, leg_h=1.5, tail=3.0, arm_pose=None):
    """
    Chunky cartoon biped dinosaur (~6.5 studs tall), standing at the origin, facing -Z: big round
    head with a short snout, glossy eyes and a smile; pear-shaped body with a cream belly; thick
    legs with round feet; tiny arms; a tapering tail curving back (+Z) and down.

    parts: role -> piece: "skin", "belly", "face" (eyes / smile), "shine" (eye highlights),
           "tail" (same colour as skin; its own piece so the rig keeps it in Torso), optional
           "spots" (back markings).
    arm_pose: {"left": (outward deg, forward deg), "right": (...)}; default relaxed.
    Returns anchors: hip, neck, head (centre), head_r, head_top, snout_tip, chest (front), hands,
    shoulder_y, belly_front_z.

    Example:
        a = dino_biped({"skin": skin, "belly": belly, "face": face, "shine": shine, "tail": tail})
        rig_split(m, dino_bones(a), assign={"Tail": "Torso"})
    """
    skin, belly, face = parts["skin"], parts["belly"], parts["face"]
    shine, tail_piece = parts.get("shine"), parts["tail"]
    bw, bh, bd = body
    # Legs: thigh ellipsoid + round foot (three toe bumps at the front).
    hip = leg_h + 0.35
    for sx in (-1, 1):
        x = sx * bw * 0.48
        ellipsoid(skin, (x, hip - 0.35, 0.05), (0.55, 0.75, 0.6), rings=5, segments=8)
        block(skin, (x, leg_h * 0.45, 0.0), (0.7, leg_h * 0.7, 0.75), bevel=0.25)
        ellipsoid(skin, (x, 0.3, -0.15), (0.55, 0.32, 0.75), rings=4, segments=8)
        for t in (-1, 0, 1):
            ellipsoid(belly, (x + t * 0.27, 0.22, -0.82), (0.14, 0.13, 0.13), rings=3, segments=6)
    # Body: pear ellipsoid + cream belly patch on the front.
    body_c = (0.0, hip + bh * 0.75, 0.1)
    ellipsoid(skin, body_c, (bw, bh, bd), rings=8, segments=12)
    belly_front_z = body_c[2] - bd * 0.86
    oriented_ellipsoid(
        belly,
        (0.0, body_c[1] - bh * 0.12, body_c[2] - bd * 0.62),
        (bw * 0.62, bh * 0.72, 0.42),
        normal=(0, 0, -1),
        rings=5,
        segments=10,
    )
    # Tail: one tapering tube from the back of the body, curving up then down toward the ground.
    path = []
    radii = []
    for i in range(6):
        t = i / 5
        z = body_c[2] + bd * 0.55 + tail * t
        y = body_c[1] - bh * 0.35 - 1.2 * t * t + 0.25 * math.sin(t * math.pi)
        path.append((0.0, y, z))
        radii.append(0.62 * (1 - t) + 0.12)
    tube(tail_piece, path, 0.5, sides=8, radii=radii)
    # Neck + head: the head sits on top of the body, a little forward.
    neck = body_c[1] + bh * 0.82
    hw, hh, hd = head
    head_c = (0.0, neck + hh * 0.85, -0.25)
    ellipsoid(skin, head_c, head, rings=8, segments=12)
    snout_c = (0.0, head_c[1] - hh * 0.3, head_c[2] - hd * 0.72)
    snout_r = (hw * 0.72, hh * 0.52, snout)
    ellipsoid(skin, snout_c, snout_r, rings=6, segments=10)
    eyes(face, shine, head_c, head, yaw=30.0, pitch=14.0, size=0.2, tall=1.3)
    smile(face, snout_c, snout_r, pitch=-18.0, width=34.0, depth=10.0, thickness=0.05, steps=6)
    # Nostrils: two tiny dark dots on top of the snout tip.
    for sx in (-1, 1):
        ellipsoid(face, (sx * 0.2, snout_c[1] + snout_r[1] * 0.55, snout_c[2] - snout * 0.78), (0.07, 0.05, 0.07), rings=3, segments=6)
    # Arms: tiny two-segment arms with round hands, hanging forward from the chest.
    pose = {"left": (10.0, 35.0), "right": (10.0, 35.0)}
    if arm_pose:
        pose.update(arm_pose)
    shoulder_y = body_c[1] + bh * 0.35
    hands = {}
    for side, (out, fwd) in pose.items():
        sx = -1 if side == "left" else 1
        shoulder = Vector((sx * bw * 0.78, shoulder_y, body_c[2] - bd * 0.45))
        d = rot_z(sx * out) @ rot_x(fwd) @ Vector((0.0, -1.0, 0.0))
        elbow = shoulder + d * 0.6
        hand = elbow + d * 0.55 + Vector((0, 0, -0.1))
        cylinder(skin, tuple(shoulder), tuple(elbow), 0.24, segments=6)
        cylinder(skin, tuple(elbow), tuple(hand), 0.21, segments=6)
        ellipsoid(skin, tuple(hand), (0.26, 0.26, 0.26), rings=4, segments=6)
        hands[side] = tuple(hand)
    return {
        "hip": hip,
        "neck": neck,
        "head": head_c,
        "head_r": head,
        "head_top": head_c[1] + hh,
        "snout_tip": (0.0, snout_c[1], snout_c[2] - snout),
        "chest": (0.0, shoulder_y - 0.3, belly_front_z),
        "hands": hands,
        "shoulder_y": shoulder_y,
        "shoulder_x": bw * 0.78,
        "shoulder_z": body_c[2] - bd * 0.45,
        "belly_front_z": belly_front_z,
        "body_c": body_c,
        "body": body,
        "leg_x": bw * 0.48,
    }


def dino_bones(a) -> dict:
    """
    R30 skeleton of `dino_biped` from its anchors (for models._npc_rig.rig_split). Joint = the
    first point of each segment: hip centre (Torso), neck (Head), shoulders (ArmL / ArmR), hip
    sockets (LegL / LegR). The torso bone stops below the neck so the head + snout classify as Head.
    """
    hip, neck = a["hip"], a["neck"]
    sx, sy, sz = a["shoulder_x"], a["shoulder_y"], a["shoulder_z"]
    lx = a["leg_x"]
    return {
        "Torso": ((0.0, hip, 0.1), (0.0, neck - 0.2, 0.1)),
        "Head": ((0.0, neck, -0.1), (0.0, a["head_top"], -0.4)),
        "ArmL": ((-sx, sy, sz), a["hands"]["left"]),
        "ArmR": ((sx, sy, sz), a["hands"]["right"]),
        "LegL": ((-lx, hip, 0.05), (-lx, 0.0, -0.1)),
        "LegR": ((lx, hip, 0.05), (lx, 0.0, -0.1)),
    }


# ------------------------------------------------------------------------------------------------
# D1 base: floor, arch, cliff, jungle
# ------------------------------------------------------------------------------------------------

BENCH_Z = 42.0  # bench pivot z (slot); the sand clearing is centred here
CLEARING_R = 11.0
MOUTH_HALF = 9.0  # cave mouth half width (slot x)
MOUTH_TOP = 15.0  # cave mouth top above the lot
CLIFF_FRONT = 55.0  # back cliff front face z
RETURN_Z = 46.0  # side cliff returns start here (fences end before it)


def _path_outline():
    """Sand path from the arch (z 0) widening to a round clearing in front of the cave mouth."""
    pts = []
    # Left edge going up (x < 0), clearing arc, right edge coming down.
    pts.append((-4.5, 0.0))
    pts.append((-5.5, 14.0))
    pts.append((-6.5, BENCH_Z - CLEARING_R + 1.5))
    # Arc (x, z) = (R cos a, BENCH_Z - R sin a) from the front-left join (a = 142 deg, z < BENCH_Z)
    # round the back of the clearing (z > BENCH_Z) to the front-right join (a = 398 = 38 deg).
    steps = 16
    for i in range(steps + 1):
        a = math.radians(142 + 256 * i / steps)
        pts.append((CLEARING_R * math.cos(a), BENCH_Z - CLEARING_R * math.sin(a)))
    pts.append((6.5, BENCH_Z - CLEARING_R + 1.5))
    pts.append((5.5, 14.0))
    pts.append((4.5, 0.0))
    return pts


def build_floor():
    """Jungle-floor lot: one ground plate, raised moss patches, the sand path + clearing, stones."""
    m = Model("D1_Floor", SLOT_PIVOT, budget=2000)
    ground = m.piece("Ground", JUNGLE_FLOOR)
    moss = m.piece("MossPatches", MOSS)
    path = m.piece("Path", SAND)
    stones = m.piece("Stones", STONE_WARM)
    block(ground, (0, LOT_TOP / 2, SLOT_D / 2), (SLOT_W, LOT_TOP, SLOT_D), bevel=0.1)
    # Sand path + clearing (+0.06): one outline so no seam of its own.
    extrude_outline(path, _path_outline(), LOT_TOP - 0.04, LOT_TOP + 0.06)
    # Moss patches (+0.1): irregular octagons clear of the path.
    for i, (x, z, r) in enumerate(
        ((-30, 22, 5.5), (-40, 40, 4.5), (-22, 44, 3.5), (30, 24, 5.0), (40, 42, 4.0), (22, 30, 3.2), (-12, 20, 3.0), (13, 22, 3.2))
    ):
        outline = []
        for k in range(8):
            a = 2 * math.pi * k / 8 + _hash(i, 2)
            rr = r * (0.8 + 0.35 * _hash(i * 7 + k, 4))
            outline.append((x + rr * math.cos(a), z + rr * math.sin(a)))
        extrude_outline(moss, outline, LOT_TOP - 0.04, LOT_TOP + 0.1)
    # Stepping stones along the path (+0.18), flat rounded discs.
    for i, z in enumerate((3.5, 8.0, 12.5, 17.0, 21.5, 26.0)):
        x = (_hash(i, 9) - 0.5) * 2.0
        disc(stones, (x, LOT_TOP - 0.02, z), 1.15 + 0.2 * _hash(i, 3), 0.2, segments=8, bevel=0.06)
    return m


def build_arch():
    """CAVE WORKSHOP arch: mossy boulder posts, log-framed plank board, bone crest, pebble finials."""
    return dino_arch("D1_EntryArch", ["CAVE", "WORKSHOP"])


def _cliff_column(rock, dark, moss, x0, x1, z_front, depth, height, seed, open_below=0.0):
    """
    One stepped cliff column spanning x0..x1 with its front face at z_front (+Z = into the cliff):
    three stacked tiers stepping back, a moss cap overhanging the top tier, a lumpy boulder or two
    on top (organic silhouette) and a moss drape over the front edge of the middle tier.
    `open_below` leaves the space under that height open (the cave mouth). Heights and front
    offsets are hashed so neighbours never share a face plane (R18).
    """
    w = x1 - x0
    xc = (x0 + x1) / 2
    z_front = z_front + 0.7 * _hash(seed, 41)  # jittered front: the wall is not one flat plane
    depth = depth - (z_front - CLIFF_FRONT)
    # Middle tier juts out over the base on every third column (a little overhang), else steps back.
    mid_inset = -0.8 if seed % 3 == 1 else 0.9
    tiers = ((0.0, 0.55, 0.0, rock), (0.55, 0.82, mid_inset, dark), (0.82, 1.0, 1.9, rock))
    for f0, f1, inset, piece in tiers:
        # Columns stand ON the lot (bottom y = LOT_TOP): no buried overlap with D1_Floor (R24).
        y0, y1 = max(LOT_TOP, height * f0), height * f1
        if y0 < open_below:
            y0 = open_below
        if y1 <= y0 + 0.2:
            continue
        d = depth - inset
        block(piece, (xc, (y0 + y1) / 2, z_front + inset + d / 2), (w - inset * 0.4, y1 - y0, d), bevel=0.45)
    block(moss, (xc, height + 0.3, z_front + 1.9 + (depth - 1.9) / 2), (w - 0.6, 0.7, depth - 1.6), bevel=0.3)
    # Boulders on top: break the straight skyline.
    for k in range(1 + int(w > 9.0)):
        bx = x0 + w * (0.3 + 0.4 * k + 0.1 * _hash(seed, 50 + k))
        r = 1.6 + 1.2 * _hash(seed, 60 + k)
        boulder(rock if (seed + k) % 2 else dark, (bx, height + 0.6 + r * 0.45, z_front + 3.5 + 2.0 * _hash(seed, 70 + k)), (r * 1.3, r, r * 1.1), seed=seed * 7 + k)
    # Moss drape over the front edge of the middle tier (proud of the tier front by 0.15).
    y_edge = height * 0.82
    if y_edge > open_below + 1.0:
        drape_w = w * (0.45 + 0.3 * _hash(seed, 80))
        dx = (w - drape_w) * (_hash(seed, 81) - 0.5) * 0.6
        block(moss, (xc + dx, y_edge - 0.6, z_front + mid_inset - 0.15 + 0.3), (drape_w, 1.6, 0.6), bevel=0.25)


def build_cave_cliff():
    """
    Mossy sandstone cliff (slot pivot): a back wall across x in [-52, 52] (front face z 55) with a
    rounded cave mouth at the centre (x +-9, 15 high, dark throat) and two side returns along the
    slot edges (z 46..70). Moss caps, hanging vines over the mouth, ferns + boulders at the foot,
    and a few amber crystals in the rock. <= 6,000 triangles (spec §16).
    """
    m = Model("D1_CaveCliff", SLOT_PIVOT + "; cliff front face z = 55, cave mouth x +-8 (13 high)", budget=6000)
    rock = m.piece("Rock", STONE)
    dark = m.piece("RockDark", STONE_DARK)
    warm = m.piece("RockWarm", STONE_WARM)
    moss = m.piece("Moss", MOSS)
    throat = m.piece("Tunnel", CAVE_DARK, material="Smooth")
    vines = m.piece("Vines", FERN_DARK)
    ferns = m.piece("Ferns", FERN)
    amber = m.piece("AmberRock", AMBER, material="Smooth")
    # Back wall columns (cut at the mouth: the two columns over it start at the mouth top).
    edges = [-52.0, -43.0, -33.0, -23.0, -14.0, -MOUTH_HALF, MOUTH_HALF, 14.0, 23.0, 33.0, 43.0, 52.0]
    for i in range(len(edges) - 1):
        x0, x1 = edges[i], edges[i + 1]
        h = 19.0 + 7.0 * _hash(i, 17) + (3.0 if abs((x0 + x1) / 2) < 10 else 0.0)
        over_mouth = x0 >= -MOUTH_HALF - 0.01 and x1 <= MOUTH_HALF + 0.01
        tones = (rock, dark, warm)
        _cliff_column(tones[i % 3], tones[(i + 1) % 3], moss, x0, x1, CLIFF_FRONT, SLOT_D - CLIFF_FRONT, h, i, open_below=MOUTH_TOP if over_mouth else 0.0)
    # Side returns: columns along the slot edges, inner face toward the lot.
    for sx in (-1, 1):
        for j, (z0, z1) in enumerate(((RETURN_Z, 55.0),)):
            h = 14.0 + 4.0 * _hash(j + 20, 5 + sx)
            xc = sx * 48.0
            block(dark if j % 2 == 0 else rock, (xc, LOT_TOP + (h * 0.6 - LOT_TOP) / 2, (z0 + z1) / 2), (8.0, h * 0.6 - LOT_TOP, z1 - z0), bevel=0.45)
            block(rock, (xc + sx * 0.6, h * 0.6 + h * 0.2, (z0 + z1) / 2 + 0.4), (6.8, h * 0.4, z1 - z0 - 0.8), bevel=0.45)
            block(moss, (xc + sx * 0.6, h + 0.3, (z0 + z1) / 2 + 0.4), (6.2, 0.7, z1 - z0 - 1.6), bevel=0.3)
    # Cave mouth: a rounded rim of boulders following a half-ellipse, a dark throat behind it.
    box(throat, (0.0, LOT_TOP + (MOUTH_TOP - LOT_TOP) / 2 + 0.05, CLIFF_FRONT + 4.0), (2 * MOUTH_HALF + 0.8, MOUTH_TOP - LOT_TOP + 0.3, 7.6))
    # Rim stones sit mostly on the wall face around the opening (never floating in the dark).
    rim = 9
    for k in range(rim):
        a = math.pi * (k + 0.5) / rim
        x = -math.cos(a) * (MOUTH_HALF + 1.3)
        y = LOT_TOP + math.sin(a) * (MOUTH_TOP - LOT_TOP + 0.9)
        boulder(rock if k % 2 else warm, (x, y, CLIFF_FRONT - 0.5), (1.8, 1.5, 1.1), seed=40 + k)
    # Boulder skirt along the cliff foot: hides the straight bottom edge of the wall.
    for k, x in enumerate((-49.0, -43.5, -35.0, -27.0, -13.0, 13.0, 27.0, 35.0, 43.5, 49.0)):
        r = 1.5 + 0.9 * _hash(k, 91)
        boulder(dark if k % 2 else warm, (x, LOT_TOP + r * 0.72, CLIFF_FRONT + 0.2), (r * 1.4, r, r * 1.0), seed=200 + k)
    # Hanging vines over the mouth: thin wavy tubes with leaf blobs.
    for k, x in enumerate((-6.0, -3.2, -0.4, 2.6, 5.4)):
        length = 3.0 + 2.5 * _hash(k, 8)
        top = MOUTH_TOP + 0.5
        pts = [(x + 0.3 * math.sin(t * 2.4 + k), top - length * t, CLIFF_FRONT - 1.75 - 0.15 * t) for t in (0.0, 0.33, 0.66, 1.0)]
        tube(vines, pts, 0.1, sides=5)
        ellipsoid(vines, pts[-1], (0.3, 0.38, 0.22), rings=3, segments=6)
    # Ferns and boulders along the cliff foot (clear of the mouth and the torch walls at x +-20).
    for k, x in enumerate((-46.0, -38.0, -31.0, -12.5, 12.5, 31.0, 38.0, 46.0)):
        fern(ferns, (x, LOT_TOP, CLIFF_FRONT - 1.6), size=1.15, seed=60 + k, fronds=5)
    # Amber crystals set into the rock face (soft Smooth glow, R19).
    for k, (x, y) in enumerate(((-27.0, 9.0), (-38.0, 15.0), (19.0, 11.5), (40.0, 7.0), (-17.0, 16.0))):
        revolve(amber, [(0.0, -0.3), (0.55, -0.3), (0.62, 0.6), (0.0, 1.5)], center=(x, y, CLIFF_FRONT - 0.15), segments=5, rot=rot_x(-70) @ rot_z(18 * (k - 2)))
    return m


def build_jungle():
    """
    Palms, ferns and boulders framing the lot (slot pivot). Split into -X ("L") and +X ("R")
    pieces so no single piece's box spans the lot in front of the producer (owner R31 / R32).
    """
    m = Model("D1_Jungle", SLOT_PIVOT, budget=3200)
    trunks = {-1: m.piece("TrunksL", BARK), 1: m.piece("TrunksR", BARK)}
    leaves = {-1: m.piece("LeavesL", FERN), 1: m.piece("LeavesR", FERN)}
    ferns = {-1: m.piece("FernsL", FERN_DARK), 1: m.piece("FernsR", FERN_DARK)}
    rocks = {-1: m.piece("RocksL", STONE), 1: m.piece("RocksR", STONE)}
    nuts = m.piece("Coconuts", BARK)
    for k, (x, z, h) in enumerate(((-44.0, 20.0, 11.0), (-38.0, 4.5, 9.0), (44.0, 22.0, 10.5), (39.0, 4.5, 9.5), (-30.0, 36.0, 9.0), (38.0, 32.0, 8.5))):
        side = -1 if x < 0 else 1
        palm(trunks[side], leaves[side], (x, LOT_TOP - 0.1, z), height=h, seed=k + 1, nuts=nuts if k < 2 else None)
    for k, (x, z) in enumerate(((-48.0, 30.0), (-34.0, 19.0), (-24.0, 2.0), (48.0, 31.0), (34.0, 19.0), (25.0, 2.0), (-9.0, 37.0), (11.0, 34.0))):
        side = -1 if x < 0 else 1
        fern(ferns[side], (x, LOT_TOP, z), size=0.9 + 0.3 * _hash(k, 1), seed=100 + k)
    for k, (x, z, r) in enumerate(((-46.0, 18.0, 1.4), (-29.0, 28.0, 1.0), (47.0, 18.0, 1.3), (28.0, 29.0, 1.1))):
        side = -1 if x < 0 else 1
        boulder(rocks[side], (x, LOT_TOP + r * 0.72, z), (r * 1.3, r, r * 1.1), seed=120 + k)
    return m


# ------------------------------------------------------------------------------------------------
# D1 builds
# ------------------------------------------------------------------------------------------------

SLAB_TOP = 3.5  # bench slab top above the bench pivot


def build_stone_bench():
    """
    The Cave Workshop producer: a thick sandstone slab on two boulder legs, a glowing pebble nuke
    hovering over a moss pad in the middle (all `Nuke*` pieces bob as ONE group, R25), a chisel and
    a bone-handled mallet on the right, a pebble pile on the left. Front (-Z) faces the customers.
    """
    m = Model("D1_StoneBench", "ground centre of the bench; customers on -Z; slab top y = 3.5", budget=3000)
    legs = m.piece("Legs", STONE_DARK)
    slab = m.piece("Slab", STONE_WARM)
    moss = m.piece("Moss", MOSS)
    stone = m.piece("NukeStone", (226, 206, 168), material="StudsSmall")
    fins = m.piece("NukeFins", STONE_DARK, material="StudsSmall")
    band = m.piece("NukeBand", AMBER_GLOW, material="Neon")
    tools = m.piece("Tools", BONE, material="StudsSmall")
    heads = m.piece("ToolHeads", (150, 150, 156), material="StudsSmall")
    pebbles = m.piece("Pebbles", STONE, material="StudsSmall")
    for sx in (-1, 1):
        boulder(legs, (sx * 3.3, 1.35, 0.0), (1.4, 1.5, 1.5), seed=7 + sx, rings=5, segments=8)
    block(slab, (0, SLAB_TOP - 0.5, 0), (10.0, 1.0, 3.8), bevel=0.35, segments=2)
    # Moss pad under the hovering nuke (sits on the slab: bottom face on the slab top).
    disc(moss, (0, SLAB_TOP, 0.1), 1.25, 0.18, segments=10, bevel=0.06)
    # Pebble nuke: hovers 0.45 above the pad so its 0.2-stud bob never touches it.
    pebble_nuke(stone, band, fins, (0, SLAB_TOP + 0.18 + 0.45, 0.1), height=3.0)
    # Chisel (bone handle + stone blade) and mallet (bone handle + stone head) lying on the slab.
    cylinder(tools, (2.0, SLAB_TOP + 0.16, -0.6), (3.4, SLAB_TOP + 0.16, -0.9), 0.15, segments=6)
    block(heads, (1.6, SLAB_TOP + 0.14, -0.52), (0.6, 0.18, 0.36), bevel=0.05, rot=rot_y(12))
    cylinder(tools, (2.4, SLAB_TOP + 0.2, 0.7), (4.3, SLAB_TOP + 0.2, 0.9), 0.17, segments=6)
    for k in (2.4, 4.3):
        ellipsoid(tools, (k, SLAB_TOP + 0.22, 0.7 + (k - 2.4) * 0.1), (0.22, 0.22, 0.22), rings=3, segments=6)
    block(heads, (2.0, SLAB_TOP + 0.42, 0.66), (0.9, 0.84, 0.84), bevel=0.2)
    # Pebble pile on the left (rounded little stones).
    for k in range(6):
        a = 2 * math.pi * k / 6
        boulder(pebbles, (-3.0 + 0.55 * math.cos(a), SLAB_TOP + 0.22, 0.3 * math.sin(a)), (0.36, 0.26, 0.32), seed=30 + k, rings=3, segments=6)
    boulder(pebbles, (-3.0, SLAB_TOP + 0.55, 0.0), (0.34, 0.26, 0.3), seed=37, rings=3, segments=6)
    return m


def build_torch_wall():
    """
    Dry-stone wall segment (10 x 3 x 1.6) with three torches standing on it: log handles, thatch
    wraps and a small Neon flame each (separate `FlameA/B/C` pieces so every flame stays a small
    R19 accent; a `Flame` WorldFx row adds the soft flicker light).
    """
    m = Model("D1_TorchWall", "ground centre of the wall; front -Z; torches on top", budget=1500)
    rock = m.piece("Rock", STONE)
    dark = m.piece("RockDark", STONE_DARK)
    moss = m.piece("Moss", MOSS)
    stick = m.piece("Sticks", LOG)
    wrap = m.piece("Wraps", THATCH)
    # Two courses of rounded stones (alternating tones), a moss line on top.
    xs = (-4.0, -1.35, 1.35, 4.0)
    for k, x in enumerate(xs):
        block(rock if k % 2 == 0 else dark, (x, 0.75, 0.0), (2.55, 1.5, 1.6), bevel=0.3)
    for k, x in enumerate((-2.7, 0.0, 2.7)):
        block(dark if k % 2 == 0 else rock, (x, 2.2, 0.05), (2.6, 1.4, 1.4), bevel=0.3)
    for x in (-4.6, 4.6):
        block(rock, (x, 2.1, 0.05), (0.75, 1.2, 1.35), bevel=0.2)
    block(moss, (0.0, 3.02, 0.05), (9.4, 0.25, 1.1), bevel=0.1)
    for k, x in enumerate((-3.4, 0.0, 3.4)):
        cylinder(stick, (x, 2.9, 0.05), (x, 5.1, 0.05), 0.2, segments=6, radius_b=0.26)
        cylinder(wrap, (x, 4.6, 0.05), (x, 5.25, 0.05), 0.34, segments=7)
        flame = m.piece(f"Flame{'ABC'[k]}", (255, 156, 50), material="Neon")
        revolve(flame, [(0.0, 0.0), (0.34, 0.15), (0.3, 0.5), (0.14, 0.85), (0.0, 1.1)], center=(x, 5.25, 0.05), segments=7)
    return m


def build_bone_tools():
    """
    Log rack (two posts + crossbar) with cartoon bone tools hanging from rope loops — a bone hammer,
    a bone pick and a rounded bone saw — plus a stump with a bone wrench lying on it.
    """
    m = Model("D1_BoneTools", "ground centre of the rack; front -Z", budget=1600)
    logs = m.piece("Logs", BARK)
    ends = m.piece("LogEnds", LOG_END)
    bones = m.piece("Bones", BONE, material="StudsSmall")
    heads = m.piece("Heads", (160, 156, 150), material="StudsSmall")
    rope = m.piece("Rope", THATCH, material="StudsSmall")
    for sx in (-1, 1):
        log(logs, (sx * 3.0, 0.0, 0.0), (sx * 3.0, 4.6, 0.0), 0.32, segments=7)
    log(logs, (-3.6, 4.2, 0.0), (3.6, 4.2, 0.0), 0.3, segments=7, ends=ends)
    # Tools hang below the bar at x -1.8 / 0 / 1.8.
    for k, x in enumerate((-1.8, 0.0, 1.8)):
        cylinder(rope, (x, 4.2, -0.05), (x, 3.75, -0.05), 0.07, segments=5)
        if k == 0:  # hammer: bone handle, rounded stone head
            bone(bones, (x, 3.6, 0.0), (x, 1.8, 0.0), 0.12, knob=0.18, segments=6)
            block(heads, (x, 1.75, 0.0), (1.1, 0.6, 0.6), bevel=0.18)
        elif k == 1:  # pick: bone handle with a curved stone blade
            bone(bones, (x, 3.6, 0.0), (x, 1.6, 0.0), 0.12, knob=0.18, segments=6)
            tube(heads, [(x - 0.8, 1.7, 0.0), (x - 0.3, 1.9, 0.0), (x + 0.3, 1.9, 0.0), (x + 0.8, 1.7, 0.0)], 0.13, sides=5, radii=[0.06, 0.16, 0.16, 0.06])
        else:  # saw: bone handle + rounded stone blade with gentle scallops
            bone(bones, (x, 3.6, 0.0), (x, 2.9, 0.0), 0.12, knob=0.18, segments=6)
            outline = [(x - 0.35, 2.85), (x + 0.35, 2.85), (x + 0.35, 1.1), (x + 0.12, 0.95), (x - 0.12, 1.05), (x - 0.35, 0.95)]
            prism(heads, [(px, py, 0.0) for px, py in outline], (0, 0, 1), 0.12)
    # Stump with a bone wrench.
    cylinder(logs, (4.6, 0.0, -0.6), (4.6, 1.2, -0.6), 0.75, segments=8)
    cylinder(ends, (4.6, 1.18, -0.6), (4.6, 1.24, -0.6), 0.64, segments=8)
    bone(bones, (4.1, 1.42, -0.9), (5.1, 1.42, -0.3), 0.11, knob=0.16, segments=6)
    return m


def build_cave_paintings():
    """
    A standing painted rock (11 x 7, rounded outline) on two boulder feet; its road-side face shows
    original doodles: a long-neck dino with a baby, a tiny two-legged dino waving, a sun with rays
    and a pebble nuke with an amber band. Paint shapes are thin plates 0.06-0.1 proud of the face,
    never overlapping one another (R18). The back is plain rock.
    """
    m = Model("D1_CavePaintings", "ground centre; painted face toward -Z", budget=1600)
    rock = m.piece("Rock", SAND_DARK)
    feet = m.piece("Feet", STONE_DARK)
    ochre = m.piece("PaintOchre", (226, 120, 60), material="Smooth")
    red = m.piece("PaintRed", (200, 70, 60), material="Smooth")
    sun = m.piece("PaintSun", (255, 204, 60), material="Smooth")
    green = m.piece("PaintGreen", (70, 150, 80), material="Smooth")
    for sx in (-1, 1):
        boulder(feet, (sx * 3.6, 0.7, 0.0), (1.5, 1.0, 1.3), seed=90 + sx)
    # Rock slab: rounded octagon outline in the XY plane, 1.2 thick.
    cx, cy = 0.0, 4.6
    outline = []
    for k in range(12):
        a = 2 * math.pi * (k + 0.5) / 12
        outline.append((cx + 5.6 * math.cos(a) * (1.0 + 0.05 * _hash(k, 1)), cy + 3.6 * math.sin(a), 0.0))
    prism(rock, outline, (0, 0, 1), 1.2)
    face = -0.6  # front face z
    z1, z2 = face - 0.06, face - 0.1

    def paint(piece, pts, z):
        prism(piece, [(x, y, z + 0.03) for x, y in pts], (0, 0, 1), 0.06)

    # Long-neck dino (ochre): body ellipse + neck + head + tail + legs, as one outline.
    body = []
    for k in range(10):
        a = 2 * math.pi * k / 10
        body.append((-2.3 + 1.5 * math.cos(a), 3.6 + 0.8 * math.sin(a)))
    paint(ochre, body, z1)
    paint(ochre, [(-1.3, 3.9), (-0.8, 4.2), (-0.3, 6.0), (-0.7, 6.1)], z1)  # neck (overlaps body: same piece)
    paint(ochre, [(-0.9, 5.9), (0.1, 6.1), (0.15, 6.5), (-0.8, 6.55)], z1)  # head
    paint(ochre, [(-3.6, 3.7), (-4.9, 3.2), (-3.5, 3.3)], z1)  # tail
    for x in (-3.1, -1.6):
        paint(ochre, [(x - 0.2, 3.1), (x + 0.2, 3.1), (x + 0.2, 2.4), (x - 0.2, 2.4)], z1)
    # Baby long-neck (ochre, smaller) beside it.
    baby = [(-4.3 + 0.6 * math.cos(2 * math.pi * k / 8), 2.6 + 0.35 * math.sin(2 * math.pi * k / 8)) for k in range(8)]
    paint(ochre, baby, z1)
    paint(ochre, [(-3.85, 2.7), (-3.65, 2.8), (-3.55, 3.2), (-3.75, 3.2)], z1)
    # Little two-legged dino waving (red).
    paint(red, [(1.6 + 0.55 * math.cos(2 * math.pi * k / 8), 3.4 + 0.75 * math.sin(2 * math.pi * k / 8)) for k in range(8)], z1)
    paint(red, [(1.4 + 0.45 * math.cos(2 * math.pi * k / 8), 4.55 + 0.38 * math.sin(2 * math.pi * k / 8)) for k in range(8)], z2)
    paint(red, [(1.4, 2.7), (1.6, 2.7), (1.6, 2.2), (1.4, 2.2)], z1)
    paint(red, [(1.85, 2.7), (2.05, 2.7), (2.05, 2.2), (1.85, 2.2)], z1)
    paint(red, [(2.1, 3.7), (2.9, 4.5), (2.75, 4.65), (2.0, 3.95)], z2)  # waving arm
    paint(red, [(2.1, 3.1), (2.9, 2.7), (2.95, 2.9), (2.15, 3.3)], z2)  # tail
    # Sun with rays (yellow), top right.
    sun_c = (3.6, 6.3)
    paint(sun, [(sun_c[0] + 0.6 * math.cos(2 * math.pi * k / 10), sun_c[1] + 0.6 * math.sin(2 * math.pi * k / 10)) for k in range(10)], z1)
    for k in range(8):
        a = 2 * math.pi * k / 8
        r0, r1 = 0.8, 1.15
        p0 = (sun_c[0] + r0 * math.cos(a), sun_c[1] + r0 * math.sin(a))
        p1 = (sun_c[0] + r1 * math.cos(a), sun_c[1] + r1 * math.sin(a))
        n = (-math.sin(a) * 0.08, math.cos(a) * 0.08)
        paint(sun, [(p0[0] + n[0], p0[1] + n[1]), (p1[0] + n[0], p1[1] + n[1]), (p1[0] - n[0], p1[1] - n[1]), (p0[0] - n[0], p0[1] - n[1])], z1)
    # Pebble nuke doodle (green body, sun-yellow band at the deeper layer), bottom right.
    nuke = [(3.9 + 0.5 * math.cos(2 * math.pi * k / 10), 2.6 + 0.85 * math.sin(2 * math.pi * k / 10)) for k in range(10)]
    paint(green, nuke, z1)
    paint(green, [(3.6, 3.3), (4.2, 3.3), (3.9, 3.95)], z1)
    paint(sun, [(3.35, 2.5), (4.45, 2.5), (4.45, 2.75), (3.35, 2.75)], z2)
    return m


def build_fire_pit():
    """
    Cozy fire pit: a ring of eight rounded stones, a four-log teepee, a dark ember bed and two
    layered Neon flames (small: R19 accents; `Flame*` pieces). An invisible `SteamAnchor` piece
    above the flames is where the WorldFx `Steam` row puts its soft puffs (campfire smoke).
    """
    m = Model("D1_FirePit", "ground centre of the pit; flames at y ~1-3", budget=1600)
    stones = m.piece("Stones", STONE)
    dark = m.piece("StonesDark", STONE_DARK)
    logs = m.piece("Logs", BARK)
    embers = m.piece("Embers", (120, 52, 40), material="Smooth")
    outer = m.piece("FlameOuter", (255, 140, 46), material="Neon")
    inner = m.piece("FlameInner", FLAME_YELLOW, material="Neon")
    anchor = m.piece("SteamAnchor", (240, 240, 240), material="Smooth", transparency=1.0)
    for k in range(8):
        a = 2 * math.pi * k / 8
        boulder(stones if k % 2 == 0 else dark, (2.3 * math.cos(a), 0.45, 2.3 * math.sin(a)), (0.75, 0.6, 0.7), seed=140 + k)
    disc(embers, (0, 0.0, 0), 1.6, 0.25, segments=10, bevel=0.06)
    for k in range(4):
        a = 2 * math.pi * (k + 0.5) / 4
        foot = (1.45 * math.cos(a), 0.2, 1.45 * math.sin(a))
        top = (0.25 * math.cos(a), 2.0, 0.25 * math.sin(a))
        log(logs, foot, top, 0.2, segments=6)
    revolve(outer, [(0.0, 0.0), (0.75, 0.3), (0.62, 1.0), (0.3, 1.7), (0.0, 2.2)], center=(0, 0.25, 0), segments=8)
    revolve(inner, [(0.0, 0.0), (0.4, 0.25), (0.34, 0.8), (0.0, 1.35)], center=(-0.05, 0.3, -0.62), segments=7)
    box(anchor, (0, 3.0, 0), (0.3, 0.3, 0.3))
    return m


def build_leaf_bellows():
    """
    Giant-leaf bellows on a log A-frame: two big leaf plates (top + bottom boards) with a pleated
    brown "leather" body between them, log handles at the back and a bamboo nozzle pointing -Z
    (place it facing the fire pit).
    """
    m = Model("D1_LeafBellows", "ground centre of the frame; nozzle points -Z", budget=1500)
    frame = m.piece("Frame", BARK)
    leaf = m.piece("Leaves", FERN)
    vein = m.piece("Veins", (190, 230, 120), material="Smooth")
    pleat = m.piece("Pleats", (160, 104, 64))
    nozzle = m.piece("Nozzle", BAMBOO)
    # A-frame legs (front and back pairs) and a top rest bar.
    for sz in (-1, 1):
        for sx in (-1, 1):
            cylinder(frame, (sx * 1.6, 0.0, sz * 1.4), (sx * 0.9, 2.4, sz * 1.4), 0.2, segments=6)
        cylinder(frame, (-1.2, 1.6, sz * 1.4), (1.2, 1.6, sz * 1.4), 0.16, segments=6)
    # Leaf boards: a pointed leaf outline (tip toward -Z), top board tilted open a little.
    leaf_pts = [(0.0, 0.0, -2.6), (1.0, 0.0, -1.4), (1.25, 0.0, 0.4), (0.8, 0.0, 1.8), (0.0, 0.0, 2.2), (-0.8, 0.0, 1.8), (-1.25, 0.0, 0.4), (-1.0, 0.0, -1.4)]
    for y, tilt in ((2.55, 0.0), (3.55, -9.0)):
        r = rot_x(tilt)
        pts = []
        for p in leaf_pts:
            v = r @ Vector(p)
            pts.append((v.x, y + v.y, v.z))
        prism(leaf, pts, tuple(r @ Vector((0, 1, 0))), 0.16)
        # Midrib vein on top of each board (+0.1 proud).
        a = r @ Vector((0, 0.11, -2.2))
        b = r @ Vector((0, 0.11, 1.9))
        cylinder(vein, (a.x, y + a.y, a.z), (b.x, y + b.y, b.z), 0.06, segments=5)
    # Pleated body between the boards (three stacked rounded bands, slightly inset).
    for k, y in enumerate((2.82, 3.05, 3.28)):
        block(pleat, (0.0, y, 0.2), (1.9 - 0.12 * (k % 2), 0.2, 3.0 - 0.2 * k), bevel=0.08)
    # Bamboo nozzle with ring joints, pointing -Z out of the front.
    cylinder(nozzle, (0.0, 2.95, -1.7), (0.0, 2.95, -4.0), 0.24, segments=7, radius_b=0.17)
    for z in (-2.5, -3.4):
        cylinder(nozzle, (0.0, 2.95, z - 0.06), (0.0, 2.95, z + 0.06), 0.27, segments=7)
    # Handles at the back.
    for y in (2.55, 3.75):
        cylinder(frame, (0.0, y, 2.0), (0.0, y + 0.1, 3.0), 0.13, segments=5)
    return m


def build_rocky_raptor():
    """
    Rocky Raptor (D1 Manager, owner R30): a round orange raptor with darker back stripes, a cream
    belly, a brown leather work apron with a pocket, a little yellow cap and a stone chisel in the
    right hand. Split into the R30 rig groups (Torso / Head / ArmL / ArmR / LegL / LegR; the tail
    and apron ride the Torso, the chisel rides ArmR).
    """
    from models._npc_rig import rig_split

    m = Model("D1_RockyRaptor", "ground centre between the feet; faces -Z", budget=3000)
    skin = m.piece("Skin", (244, 150, 66), material="Smooth")
    tail = m.piece("Tail", (244, 150, 66), material="Smooth")
    belly = m.piece("Belly", (255, 226, 176), material="Smooth")
    face = m.piece("Face", INK, material="Smooth")
    shine = m.piece("Shine", (255, 255, 255), material="Smooth")
    stripes = m.piece("Stripes", (214, 104, 44), material="Smooth")
    apron = m.piece("Apron", (150, 96, 58), material="StudsSmall")
    cap = m.piece("Cap", (255, 214, 60), material="StudsSmall")
    chisel = m.piece("Chisel", (170, 166, 160), material="StudsSmall")
    a = dino_biped(
        {"skin": skin, "belly": belly, "face": face, "shine": shine, "tail": tail},
        body=(1.3, 1.5, 1.2),
        head=(1.05, 0.95, 1.05),
        snout=0.8,
        arm_pose={"left": (12.0, 25.0), "right": (8.0, 60.0)},
    )
    bx, by, bz = a["body_c"]
    bw, bh, bd = a["body"]
    # Back stripes: three curved bands across the back (+Z side of the body).
    for k, dy in enumerate((0.7, 0.1, -0.5)):
        pts = []
        for i in range(5):
            t = -1 + 2 * i / 4
            ang = math.radians(60 * t)
            y = by + dy
            ry = math.sqrt(max(0.05, 1 - (dy / bh) ** 2))
            pts.append((bw * ry * 1.01 * math.sin(ang), y, bz + bd * ry * 1.01 * math.cos(ang)))
        tube(stripes, pts, 0.13, sides=5)
    hx, hy, hz = a["head"]
    hw, hh, hd = a["head_r"]
    for k, dz in enumerate((0.15, 0.6)):
        tube(stripes, [(-hw * 0.5, hy + hh * 0.8, hz + dz), (0.0, hy + hh * 1.0, hz + dz), (hw * 0.5, hy + hh * 0.8, hz + dz)], 0.1, sides=5)
    # Leather apron: a plate over the belly with a neck strap and a pocket.
    hip = a["hip"]
    front = a["belly_front_z"] - 0.12
    apron_pts = [(-0.62, hip + 1.6, front), (0.62, hip + 1.6, front), (0.85, hip + 0.35, front), (0.0, hip + 0.15, front), (-0.85, hip + 0.35, front)]
    prism(apron, apron_pts, (0, 0, 1), 0.14)
    block(apron, (0.0, hip + 0.8, front - 0.12), (0.7, 0.45, 0.1), bevel=0.04)
    tube(apron, [(-0.55, hip + 1.6, front), (-0.5, hip + 2.4, bz - bd * 0.35), (0.5, hip + 2.4, bz - bd * 0.35), (0.55, hip + 1.6, front)], 0.07, sides=4)
    # Cap: a dome with a short brim pointing forward.
    top = a["head_top"]
    revolve(cap, [(0.0, 0.0), (0.82, 0.0), (0.72, 0.35), (0.4, 0.55), (0.0, 0.6)], center=(hx, top - 0.2, hz + 0.1), segments=10)
    block(cap, (hx, top - 0.15, hz - 0.85), (1.1, 0.1, 0.7), bevel=0.04)
    # Chisel in the right hand: stone blade with a bone-cream grip (same chisel piece colour).
    rx, ry, rz = a["hands"]["right"]
    cylinder(chisel, (rx, ry - 0.1, rz), (rx, ry + 0.75, rz - 0.15), 0.1, segments=5)
    block(chisel, (rx, ry + 0.95, rz - 0.18), (0.32, 0.4, 0.12), bevel=0.04)
    rig_split(m, dino_bones(a), assign={"Tail": "Torso", "Apron": "Torso", "Chisel": "ArmR", "Cap": "Head"})
    return m


def build_log_fence():
    """16-stud log fence run (pivot = ground centre, runs along X, front -Z): 3 posts, 2 rails."""
    m = Model("D1_LogFence", "ground centre of the run; runs along X (16 long)", budget=700)
    logs = m.piece("Logs", LOG)
    ends = m.piece("LogEnds", LOG_END)
    rope = m.piece("Rope", THATCH, material="StudsSmall")
    for x in (-7.5, 0.0, 7.5):
        cylinder(logs, (x, 0.0, 0.0), (x, 3.0, 0.0), 0.38, segments=7)
        cylinder(ends, (x, 2.99, 0.0), (x, 3.05, 0.0), 0.3, segments=7)
    for y in (1.1, 2.3):
        cylinder(logs, (-7.9, y, -0.45), (7.9, y, -0.45), 0.24, segments=6)
        for x in (-7.5, 0.0, 7.5):
            # Lashing: taller than the rail (+-0.34 vs the rail's 0.21 half-height) so the rope's
            # caps never share the rail's flat top plane (R18).
            cylinder(rope, (x, y - 0.34, -0.42), (x, y + 0.34, -0.42), 0.3, segments=6)
    return m


BUILDERS = {
    "D1_Floor": build_floor,
    "D1_EntryArch": build_arch,
    "D1_CaveCliff": build_cave_cliff,
    "D1_Jungle": build_jungle,
    "D1_StoneBench": build_stone_bench,
    "D1_TorchWall": build_torch_wall,
    "D1_BoneTools": build_bone_tools,
    "D1_CavePaintings": build_cave_paintings,
    "D1_FirePit": build_fire_pit,
    "D1_LeafBellows": build_leaf_bellows,
    "D1_RockyRaptor": build_rocky_raptor,
    "D1_LogFence": build_log_fence,
}
