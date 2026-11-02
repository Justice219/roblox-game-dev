"""
area01.py — Area 1 "Garage Lab" scene models (B8a) + the shared area-art helpers used by areas 1-3.

Area 1 reuses B4's garage set (tools/blender/models/area1_garage.py: Garage_* shell, Workbench,
MiniReactor, ToolWall, GlowLamp, PaintStation, Driveway) and adds what its build keys still lacked:

    A1_Lot          the suburban lawn lot (mowed stripes, front curb, stepping stones)      base
    A1_EntryArch    "GARAGE LAB" block-letter arch with pocket-nuke finials               base
    A1_Yard         chunky trees, hedges and flower beds framing the garage               base
    A1_UncleAtom    the Manager: a cute old inventor in a lab coat with goggles           A1_UncleAtom
    A1_ReactorPack  glowing coolant unit bolted to the garage's side wall                 A1_MiniReactor
    A1_NukeMobile   little family car with a pocket nuke on the roof, parked on the drive A1_Driveway

Placement lives in src/shared/Config/AreaLayouts/Area01.luau (slot-local frame, docs/areas-art.md).

SLOT-ORIGIN models (A1_Lot, A1_Yard) use the slot origin as pivot: the road-side edge midpoint at
ground level, +Z away from the road, slot x in [-52, 52], z in [0, 70]. Their layout cf is identity.
Every other model is pivoted at its own ground centre with its front toward -Z (the road).

Shared helpers exported for area02.py / area03.py (and any other area builder that wants them):

    block_text(piece, lines, center, cell, depth)   brick-pixel letters (5x7 font) readable from -Z
    text_cells(line) -> int                          width of a line in font cells
    entry_arch(key, lines, ...) -> Model             themed entry arch with a block-letter sign
    toy_figure(parts, ...) / toy_face(...)           chunky cartoon character body + face
    wheel(tyre, hub, center, radius, width)          toy wheel with its axle along X
    mini_nuke(...) / tiny_nuke(...)                  hero-prop nuke (fins) / ~84-tri crate filler
    striped_cone(a, b, center, radius, rise)         candy-striped umbrella canopy
    scallops(a, b, x0, x1, y_top, z)                 hanging half-disc awning valance
    lot_stripes(a, b, x0, x1, z0, z1, ...)            mowed-lawn / paving stripes, beveled seams
    round_tree / blocky_tree / flower_bed            yard decor
    LOT_TOP, SLOT_PIVOT, SKIN, LAWN_LIGHT, SOIL, BARK   shared constants

Text direction: a viewer facing a -Z face looks toward +Z, so their RIGHT is world -X. block_text
therefore lays glyphs from +X toward -X (otherwise every sign reads mirrored from the road).

Budgets (docs/world-art.md section 4): lots <= 1,500, decor sets / machines <= 3,000, landmark arches
<= 6,000 (they carry geometry letters). Every big face uses a stud material; letters and faces are
Smooth (tiny details where studs would be noise), lights Neon, windows Glass.
"""

from __future__ import annotations

import math

from snkit.core import (
    CHARCOAL,
    CONCRETE,
    DARK_STEEL,
    DEEP_BLUE,
    GLASS,
    GLOW_GREEN,
    GRASS,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LAMP_WARM,
    LEAF,
    LIME,
    MINT,
    Model,
    PINK,
    SIDEWALK,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    TYRE,
    WHITE,
    YELLOW,
)
from snkit.kit import block, disc, hazard_band, nuke_body, pipe, trefoil
from mathutils import Vector
from snkit.shapes import bar, box, cylinder, ellipsoid, prism, revolve, ring_tube, rot_x, rot_z

# ------------------------------------------------------------------------------------------------
# Shared constants
# ------------------------------------------------------------------------------------------------

LOT_TOP = 0.5  # every area lot is a 0.5-stud plate on the ground: walk surface y = 0.5
SLOT_PIVOT = (
    "slot origin: road-side edge midpoint at ground (y = 0); +Z away from the road; "
    "slot x -52..52, z 0..70; lot top y = 0.5"
)
SKIN = (255, 214, 172)  # cartoon skin tone for NPC characters (Smooth: studs on skin read as dirt)
LAWN_LIGHT = (128, 220, 92)  # lighter mowed-stripe green next to snkit GRASS
SOIL = (122, 82, 54)
BARK = (150, 98, 58)

# ------------------------------------------------------------------------------------------------
# Brick-pixel font: 7 rows tall, variable width. '#' = filled cell. Each glyph is decomposed into
# a few maximal rectangles (one chunky block each), so a letter costs ~3-6 blocks, not 15 cells.
# ------------------------------------------------------------------------------------------------

_FONT_SRC = {
    "A": ".###.|#...#|#...#|#####|#...#|#...#|#...#",
    "B": "####.|#...#|#...#|####.|#...#|#...#|####.",
    "C": ".###.|#...#|#....|#....|#....|#...#|.###.",
    "D": "####.|#...#|#...#|#...#|#...#|#...#|####.",
    "E": "#####|#....|#....|####.|#....|#....|#####",
    "F": "#####|#....|#....|####.|#....|#....|#....",
    "G": ".###.|#...#|#....|#.###|#...#|#...#|.###.",
    "H": "#...#|#...#|#...#|#####|#...#|#...#|#...#",
    "I": "###|.#.|.#.|.#.|.#.|.#.|###",
    "J": "..###|...#.|...#.|...#.|#..#.|#..#.|.##..",
    "K": "#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#",
    "L": "#....|#....|#....|#....|#....|#....|#####",
    "M": "#...#|##.##|#.#.#|#.#.#|#...#|#...#|#...#",
    "N": "#...#|#...#|##..#|#.#.#|#..##|#...#|#...#",
    "O": ".###.|#...#|#...#|#...#|#...#|#...#|.###.",
    "P": "####.|#...#|#...#|####.|#....|#....|#....",
    "Q": ".###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#",
    "R": "####.|#...#|#...#|####.|#.#..|#..#.|#...#",
    "S": ".####|#....|#....|.###.|....#|....#|####.",
    "T": "#####|..#..|..#..|..#..|..#..|..#..|..#..",
    "U": "#...#|#...#|#...#|#...#|#...#|#...#|.###.",
    "V": "#...#|#...#|#...#|#...#|#...#|.#.#.|..#..",
    "W": "#...#|#...#|#...#|#.#.#|#.#.#|#.#.#|.#.#.",
    "X": "#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#",
    "Y": "#...#|#...#|.#.#.|..#..|..#..|..#..|..#..",
    "Z": "#####|....#|...#.|..#..|.#...|#....|#####",
    "0": ".###.|#...#|#..##|#.#.#|##..#|#...#|.###.",
    "1": ".#.|##.|.#.|.#.|.#.|.#.|###",
    "2": ".###.|#...#|....#|...#.|..#..|.#...|#####",
    "3": "####.|....#|....#|.###.|....#|....#|####.",
    "4": "...#.|..##.|.#.#.|#..#.|#####|...#.|...#.",
    "5": "#####|#....|####.|....#|....#|#...#|.###.",
    "6": ".###.|#....|#....|####.|#...#|#...#|.###.",
    "7": "#####|....#|...#.|..#..|.#...|.#...|.#...",
    "8": ".###.|#...#|#...#|.###.|#...#|#...#|.###.",
    "9": ".###.|#...#|#...#|.####|....#|....#|.###.",
    "!": "#|#|#|#|#|.|#",
    "$": "..#..|.####|#.#..|.###.|..#.#|####.|..#..",
    "-": "....|....|....|####|....|....|....",
    "'": "#|#|.|.|.|.|.",
    " ": "..|..|..|..|..|..|..",
}


def _glyph_rects(rows):
    """
    Greedy maximal-rectangle cover of a glyph bitmap: grow right first, then down.
    Returns [(x, y, w, h)] in cells, y = 0 at the TOP row.

    Example: "H" -> two full-height strokes + one 3-cell crossbar (3 blocks instead of 13 cells).
    """
    height = len(rows)
    width = max(len(r) for r in rows)
    filled = [[x < len(r) and r[x] == "#" for x in range(width)] for r in rows]
    used = [[False] * width for _ in range(height)]
    rects = []
    for y in range(height):
        for x in range(width):
            if not filled[y][x] or used[y][x]:
                continue
            x1 = x
            while x1 + 1 < width and filled[y][x1 + 1] and not used[y][x1 + 1]:
                x1 += 1
            y1 = y
            while y1 + 1 < height and all(filled[y1 + 1][k] and not used[y1 + 1][k] for k in range(x, x1 + 1)):
                y1 += 1
            for yy in range(y, y1 + 1):
                for xx in range(x, x1 + 1):
                    used[yy][xx] = True
            rects.append((x, y, x1 - x + 1, y1 - y + 1))
    return rects


FONT = {ch: (len(src.split("|")[0]), _glyph_rects(src.split("|"))) for ch, src in _FONT_SRC.items()}
FONT_ROWS = 7


def text_cells(line: str) -> int:
    """Width of a text line in font cells (glyph widths + 1 cell between glyphs)."""
    widths = [FONT[ch][0] for ch in line.upper()]
    return sum(widths) + max(0, len(widths) - 1)


def block_text(piece, lines, center, cell, depth, line_gap=2, bevel=0.0, facing="-z"):
    """
    Chunky brick-pixel letters centred on `center`, readable from the side they face.
    facing="-z" (default): readable from the -Z side (the road). `center` z is the BACK face of the
    letters (put it on the panel's front face); letters extrude `depth` toward -Z.
    facing="+z": readable from the +Z side; letters extrude `depth` toward +Z from `center` z.
    lines: a string or list of strings (upper-cased; unknown chars fail).
    bevel: 0 (default) = crisp 12-triangle blocks. Owner rule R11 (console/mobile first): a chamfer on
    half-stud letter cells is invisible on a phone but costs 3.7x the triangles; pass e.g. 0.06 only
    for hero lettering seen up close.

    Example: block_text(m.piece("Letters", WHITE, "Smooth"), ["GARAGE", "LAB"], (0, 14, -0.5), 0.5, 0.35)
    """
    if facing not in ("-z", "+z"):
        raise ValueError(f"block_text: facing must be '-z' or '+z', not {facing!r}")
    if isinstance(lines, str):
        lines = [lines]
    cx, cy, cz = center
    # A viewer facing a -Z face looks toward +Z, so THEIR right is world -X: -Z text starts at +X
    # and advances toward -X (otherwise it reads mirrored). A +Z viewer's right is +X.
    advance = -1.0 if facing == "-z" else 1.0
    out = -1.0 if facing == "-z" else 1.0
    total_rows = len(lines) * FONT_ROWS + (len(lines) - 1) * line_gap
    top = cy + total_rows * cell / 2
    b = min(bevel, cell * 0.2)
    for li, line in enumerate(lines):
        line = line.upper()
        x = cx - advance * text_cells(line) * cell / 2
        line_top = top - li * (FONT_ROWS + line_gap) * cell
        for ch in line:
            if ch not in FONT:
                raise ValueError(f"block_text: no glyph for {ch!r}")
            width, rects = FONT[ch]
            for gx, gy, gw, gh in rects:
                block(
                    piece,
                    (x + advance * (gx + gw / 2) * cell, line_top - (gy + gh / 2) * cell, cz + out * depth / 2),
                    (gw * cell, gh * cell, depth),
                    bevel=b,
                )
            x += advance * (width + 1) * cell


def sign_text(piece, lines, center, cell, depth, half_gap, bevel=0.0):
    """
    DOUBLE-SIDED sign lettering (owner R17): the same text readable from the road (-Z) AND from
    behind (+Z). center = the board's centre; half_gap = half the board thickness (distance from the
    centre to each face). The back copy is the exact 180-degree yaw of the front copy about the
    board centre, so the piece is symmetric under that rotation and reads correctly even if a mesh
    is ever shown spun 180 degrees (Roblox's FBX import pre-rotates meshes by 180 degrees of yaw;
    see docs/areas-art.md "R17").

    Example: sign_text(letters, "GARAGE LAB", (0, 12.3, 0), 0.5, 0.4, 0.48)
    """
    cx, cy, cz = center
    block_text(piece, lines, (cx, cy, cz - half_gap), cell, depth, bevel=bevel, facing="-z")
    block_text(piece, lines, (cx, cy, cz + half_gap), cell, depth, bevel=bevel, facing="+z")


# ------------------------------------------------------------------------------------------------
# Shared builders
# ------------------------------------------------------------------------------------------------


def lot_stripes(piece_a, piece_b, x0, x1, z0, z1, stripe=8.0, top=LOT_TOP, along="z", bevel=0.12):
    """
    Fill the rectangle [x0,x1] x [z0,z1] with alternating full-thickness stripes (mowed lawn,
    paving bands). Adjacent beveled blocks leave a crisp V seam between stripes, like LEGO plates.
    along="z": stripes run toward the road (vary along X); "x": stripes run along the road.
    """
    if along == "z":
        count = max(1, round((x1 - x0) / stripe))
        width = (x1 - x0) / count
        for i in range(count):
            piece = piece_a if i % 2 == 0 else piece_b
            block(piece, (x0 + width * (i + 0.5), top / 2, (z0 + z1) / 2), (width, top, z1 - z0), bevel=bevel)
    else:
        count = max(1, round((z1 - z0) / stripe))
        depth = (z1 - z0) / count
        for i in range(count):
            piece = piece_a if i % 2 == 0 else piece_b
            block(piece, ((x0 + x1) / 2, top / 2, z0 + depth * (i + 0.5)), (x1 - x0, top, depth), bevel=bevel)


def wheel(tyre, hub, center, radius, width, segments=14):
    """Toy wheel with its axle along X: rounded tyre (revolve) + raised hub caps on both faces."""
    w = width / 2
    shoulder = min(0.22, radius * 0.2)
    profile = [
        (0.0, -w),
        (radius - shoulder, -w),
        (radius, -w + shoulder),
        (radius, w - shoulder),
        (radius - shoulder, w),
        (0.0, w),
    ]
    revolve(tyre, profile, center=center, segments=segments, rot=rot_z(90))
    cap = [(0.0, -w - 0.08), (radius * 0.52, -w - 0.08), (radius * 0.52, w + 0.08), (0.0, w + 0.08)]
    revolve(hub, cap, center=center, segments=10, rot=rot_z(90))


def toy_face(face, cheeks, center, half_depth, scale=1.0, smile=True, eyes=True):
    """
    Cartoon face on the -Z side of a head: two tall oval eyes, a U smile, rosy cheeks.
    center = head centre; half_depth = distance from the centre to the head's front face.
    eyes=False skips the oval eyes (callers drawing their own, e.g. a robot's happy "^" eyes).
    """
    cx, cy, cz = center
    zf = cz - half_depth
    s = scale
    for sx in (-1, 1) if eyes else ():
        ellipsoid(face, (cx + sx * 0.42 * s, cy + 0.15 * s, zf - 0.02), (0.16 * s, 0.25 * s, 0.09), rings=4, segments=8)
    if smile:
        # U-shaped smile: an arc band (outer radius 0.42, inner 0.28) below the eyes.
        pts_out, pts_in = [], []
        for k in range(9):
            a = math.radians(200 + 140 * k / 8)
            pts_out.append((cx + 0.42 * s * math.cos(a), cy - 0.2 * s + 0.42 * s * math.sin(a), zf - 0.03))
            pts_in.append((cx + 0.28 * s * math.cos(a), cy - 0.2 * s + 0.28 * s * math.sin(a), zf - 0.03))
        prism(face, pts_out + list(reversed(pts_in)), (0, 0, 1), 0.08)
    if cheeks is not None:
        for sx in (-1, 1):
            revolve(
                cheeks,
                [(0.0, -0.03), (0.2 * s, -0.03), (0.2 * s, 0.03), (0.0, 0.03)],
                center=(cx + sx * 0.72 * s, cy - 0.28 * s, zf - 0.01),
                segments=10,
                rot=rot_x(90),
            )


def _limb(piece, shoulder, length, thick, depth, roll=0.0, pitch=0.0, bevel=0.18):
    """
    Arm block hanging from `shoulder`, swung forward by `pitch` degrees (toward -Z) and then
    sideways by `roll` degrees about Z (positive roll swings the hand toward +X).
    Returns the far end point (the hand) so accessories can be attached there.
    """
    rot = rot_z(roll) @ rot_x(pitch)
    d = rot @ Vector((0.0, -1.0, 0.0))
    cx = shoulder[0] + d.x * length / 2
    cy = shoulder[1] + d.y * length / 2
    cz = shoulder[2] + d.z * length / 2
    box(piece, (cx, cy, cz), (thick, length, depth), rot=rot, bevel=min(bevel, 0.2 * min(thick, depth)))
    return (shoulder[0] + d.x * length, shoulder[1] + d.y * length, shoulder[2] + d.z * length)


def toy_figure(parts, height_scale=1.0, left_arm=(0.0, 0.0), right_arm=(0.0, 0.0), head_size=(2.1, 1.95, 1.85)):
    """
    Chunky chibi character (~6 studs tall) standing at the origin, facing -Z.
    parts: dict of role -> piece: "shoes", "legs", "torso", "arms", "skin", "face", "cheeks" (opt).
    left_arm / right_arm: (outward, forward) degrees. Left = the -X side. outward 0 = hanging down,
    90 = straight out sideways, 150 = waving overhead; forward swings the hand toward -Z.
    Returns a dict of anchor points: head centre/top/front, hands, chest front, hip.

    Example:
        anchors = toy_figure({"shoes": shoes, "legs": pants, "torso": coat, "arms": coat,
                              "skin": skin, "face": face, "cheeks": cheeks}, left_arm=(150, 0))
    """
    k = height_scale
    for sx in (-1, 1):
        block(parts["shoes"], (sx * 0.5, 0.23, -0.12), (0.95, 0.46, 1.35), bevel=0.15)
        block(parts["legs"], (sx * 0.5, 0.42 + 0.8 * k, 0.0), (0.9, 1.6 * k, 0.95), bevel=0.15)
    hip = 0.42 + 1.6 * k
    torso_h = 2.1 * k
    block(parts["torso"], (0, hip + torso_h / 2, 0), (2.1, torso_h, 1.15), bevel=0.25)
    shoulder_y = hip + torso_h - 0.15
    hands = {}
    for side, (roll, pitch) in (("left", left_arm), ("right", right_arm)):
        sx = -1 if side == "left" else 1
        # rot_z(+a) swings a hanging arm toward +X, so "outward" is +a on the right (+X) side and
        # -a on the left (-X) side.
        end = _limb(parts["arms"], (sx * 1.42, shoulder_y, 0.0), 1.9 * k, 0.72, 0.8, roll=sx * roll, pitch=pitch)
        ellipsoid(parts["skin"], end, (0.4, 0.4, 0.4), rings=5, segments=8)
        hands[side] = end
    hw, hh, hd = head_size
    head_c = (0.0, hip + torso_h + hh / 2 + 0.05, 0.0)
    block(parts["skin"], head_c, head_size, bevel=0.45, segments=2)
    toy_face(parts["face"], parts.get("cheeks"), head_c, hd / 2)
    return {
        "head": head_c,
        "head_top": (0.0, head_c[1] + hh / 2, 0.0),
        "head_front": (0.0, head_c[1], -hd / 2),
        "hands": hands,
        "chest": (0.0, hip + torso_h * 0.62, -0.58),
        "hip": hip,
        "shoulder_y": shoulder_y,
        "head_size": head_size,
    }


def mini_nuke(body, nose, fins, core, base, length=1.6, radius=0.38, segments=10):
    """Small pocket nuke prop (held items, roof mascots, crate fillers). Returns core band y."""
    return nuke_body(body, nose, fins, core, base=base, length=length, radius=radius, segments=segments)


def tiny_nuke(body, nose, core, base, height=1.2, radius=0.3, segments=8):
    """
    Cheap crate-filler nuke (~84 triangles): capsule body, cone nose, glowing core band, no fins.
    Use for shelves / crates / fridges where dozens sit together; mini_nuke for hero props.
    """
    bx, by, bz = base
    h_body = height * 0.62
    cylinder(body, (bx, by, bz), (bx, by + h_body, bz), radius, segments=segments)
    cylinder(nose, (bx, by + h_body, bz), (bx, by + height, bz), radius * 1.03, segments=segments, radius_b=radius * 0.18)
    if core is not None:
        cylinder(core, (bx, by + h_body * 0.42, bz), (bx, by + h_body * 0.64, bz), radius * 1.1, segments=segments)


def striped_cone(piece_a, piece_b, center, radius, rise, wedges=8, thick=0.14):
    """
    Beach-umbrella canopy: `wedges` flat triangular panels around a peak, alternating two pieces
    (candy stripes). center = rim centre; the peak sits `rise` above it.
    """
    cx, cy, cz = center
    apex = Vector((cx, cy + rise, cz))
    for k in range(wedges):
        a0 = 2 * math.pi * k / wedges
        a1 = 2 * math.pi * (k + 1) / wedges
        p0 = Vector((cx + radius * math.cos(a0), cy, cz + radius * math.sin(a0)))
        p1 = Vector((cx + radius * math.cos(a1), cy, cz + radius * math.sin(a1)))
        normal = (p1 - apex).cross(p0 - apex).normalized()
        prism(piece_a if k % 2 == 0 else piece_b, [tuple(apex), tuple(p0), tuple(p1)], tuple(normal), thick)


def scallops(piece_a, piece_b, x0, x1, y_top, z, size=1.0, segments=6, thick=0.14):
    """Row of hanging half-disc flaps (awning valance) in the XY plane at depth z, alternating pieces."""
    count = max(1, round((x1 - x0) / size))
    width = (x1 - x0) / count
    r = width / 2
    for i in range(count):
        cx = x0 + width * (i + 0.5)
        pts = [(cx - r, y_top, z), (cx + r, y_top, z)]
        for s in range(1, segments):
            a = -math.pi * s / segments
            pts.append((cx + r * math.cos(a), y_top + r * math.sin(a) * 0.9 - 0.15, z))
        prism(piece_a if i % 2 == 0 else piece_b, pts, (0, 0, 1), thick)


def entry_arch(
    key,
    lines,
    *,
    inner=20.0,
    post_h=9.0,
    post_w=3.0,
    post_color=SKY_BLUE,
    trim_color=WHITE,
    panel_color=DEEP_BLUE,
    letter_color=WHITE,
    finial_colors=(TOY_RED, MINT),
    cell=None,
    bulbs=True,
    budget=6000,
    pivot_note="",
):
    """
    Themed entry arch: two chunky posts on plinths with hazard bands, a framed sign board spanning
    them with the area name in block letters on BOTH faces (owner R17: readable from the road and
    from inside the area), marquee bulbs on both faces and a pocket-nuke finial on each post cap.
    Every piece is symmetric under a 180-degree yaw about the board centre, so the arch reads
    correctly from both sides whatever orientation the mesh import uses.

    inner: clear width between the posts (walkway). Pivot: ground centre under the board, front -Z.
    Returns the Model (callers may add theme pieces before returning it from their builder).
    """
    m = Model(key, f"ground centre between the posts; sign faces -Z (the road){pivot_note}", budget=budget)
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
    # Sign board: full width over both posts, framed, letters on the front.
    lines = [lines] if isinstance(lines, str) else list(lines)
    board_w = inner + 2 * post_w + 2.0
    widest = max(text_cells(line) for line in lines)
    pad = 1.0
    if cell is None:
        cell = min(0.62, (board_w - 2 * pad - 0.6) / widest)
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
    # Double-sided name (owner R17): readable from the road AND from inside the area.
    sign_text(letters, lines, (0, board_y, 0), cell, 0.4, depth * 0.4)
    # Post caps + pocket-nuke finials on top.
    top_y = 1.0 + post_h + board_h - 0.4
    for sx, colour in zip((-1, 1), finial_colors):
        x = sx * px
        block(trim, (x, top_y + 0.35, 0), (post_w + 0.6, 0.7, post_w + 0.6), bevel=0.2)
        nb = m.piece(f"Finial{'L' if sx < 0 else 'R'}", colour, material="StudsSmall")
        nose = m.piece("FinialNose", WHITE, material="StudsSmall")
        fins = m.piece("FinialFins", CHARCOAL, material="StudsSmall")
        core = m.piece("FinialCore", GLOW_GREEN, material="Neon")
        nuke_body(nb, nose, fins, core, base=(x, top_y + 0.7, 0), length=4.2, radius=1.0, segments=12)
    if bulbs:
        bulb = m.piece("Bulbs", LAMP_WARM, material="Neon")
        count = max(6, int(board_w / 2.2))
        for i in range(count):
            x = -board_w / 2 + 1.0 + (board_w - 2.0) * i / (count - 1)
            for sy in (-1, 1):
                # Both faces (R17: the board is double-sided); 16-triangle bulbs (R11): the Neon
                # glow hides the facets.
                for sz in (-1, 1):
                    y = board_y + sy * (board_h / 2 - frame_t / 2)
                    ellipsoid(bulb, (x, y, sz * (depth / 2 + 0.12)), (0.2, 0.2, 0.2), rings=3, segments=4)
    m.arch_info = {"board_y": board_y, "board_h": board_h, "board_w": board_w, "post_x": px, "top_y": top_y}
    return m


def blocky_tree(trunk, leaves, base, height=8.0, crown=4.6, tiers=3, segments=1):
    """
    Chunky toy tree: square trunk + stacked shrinking beveled leaf blocks (LEGO-ish pine/bush).
    segments=1 keeps a crisp chamfer (~44 triangles per tier); 2 rounds the tiers (~110).
    """
    bx, by, bz = base
    trunk_h = height * 0.38
    block(trunk, (bx, by + trunk_h / 2, bz), (1.0, trunk_h, 1.0), bevel=0.15)
    y = by + trunk_h - 0.3
    size = crown
    for _ in range(tiers):
        h = size * 0.62
        block(leaves, (bx, y + h / 2, bz), (size, h, size), bevel=0.35, segments=segments)
        y += h * 0.82
        size *= 0.7


def round_tree(trunk, leaves, base, height=8.0, crown=3.0, segments=10):
    """
    Lollipop tree: trunk + one big ball crown + two smaller side puffs (cartoon suburb).
    segments: around the main crown (10 ~ 230 triangles per tree, 8 ~ 160).
    """
    bx, by, bz = base
    trunk_h = height * 0.45
    block(trunk, (bx, by + trunk_h / 2, bz), (0.9, trunk_h, 0.9), bevel=0.15)
    cy = by + trunk_h + crown * 0.7
    rings = max(4, segments // 2 + 1)
    puff = max(6, segments - 2)
    ellipsoid(leaves, (bx, cy, bz), (crown, crown * 0.9, crown), rings=rings, segments=segments)
    ellipsoid(leaves, (bx + crown * 0.7, cy - crown * 0.35, bz - crown * 0.2), (crown * 0.55,) * 3, rings=rings - 1, segments=puff)
    ellipsoid(leaves, (bx - crown * 0.6, cy - crown * 0.25, bz + crown * 0.3), (crown * 0.5,) * 3, rings=rings - 1, segments=puff)


def flower_bed(soil, stems, petals, x0, x1, z0, z1, step=1.4, top=LOT_TOP):
    """Raised soil bed with rows of chunky flowers. petals: list of pieces cycled per flower."""
    block(soil, ((x0 + x1) / 2, top + 0.25, (z0 + z1) / 2), (x1 - x0, 0.5, z1 - z0), bevel=0.15)
    i = 0
    z = z0 + step / 2
    while z < z1 - 0.3:
        x = x0 + step / 2 + (0.5 * step if int((z - z0) / step) % 2 else 0)
        while x < x1 - 0.3:
            block(stems, (x, top + 0.9, z), (0.18, 0.8, 0.18), bevel=0.0)
            block(petals[i % len(petals)], (x, top + 1.4, z), (0.6, 0.45, 0.6), bevel=0.12)
            i += 1
            x += step
        z += step


# ------------------------------------------------------------------------------------------------
# Area 1 models
# ------------------------------------------------------------------------------------------------


def build_lot():
    """Suburban lawn lot: mowed stripes, white front curb, stepping stones arch -> garage door."""
    m = Model("A1_Lot", SLOT_PIVOT, budget=1500)
    lawn = m.piece("Lawn", GRASS)
    lawn_light = m.piece("LawnLight", LAWN_LIGHT)
    curb = m.piece("Curb", SIDEWALK)
    stones = m.piece("Stones", CONCRETE)
    lot_stripes(lawn, lawn_light, -52, 52, 2.0, 70.0, stripe=8.0)
    block(curb, (0, LOT_TOP / 2 + 0.05, 1.0), (104.0, LOT_TOP + 0.1, 2.0), bevel=0.15)
    # Stepping stones from the arch to the garage door (the Driveway later paves over them).
    z = 5.5
    while z < 31.0:
        block(stones, (0, LOT_TOP + 0.06, z), (3.2, 0.12, 1.7), bevel=0.06)
        z += 2.5
    # Concrete apron in front of the reactor-pack spot on the garage's +X side.
    block(stones, (17.0, LOT_TOP + 0.06, 40.0), (5.0, 0.12, 6.0), bevel=0.08)
    return m


def build_arch():
    """GARAGE LAB entry arch in the garage's sky-blue / white / coral palette."""
    m = entry_arch(
        "A1_EntryArch",
        "GARAGE LAB",
        inner=22.0,
        post_color=SKY_BLUE,
        trim_color=WHITE,
        panel_color=(240, 98, 78),
        letter_color=WHITE,
        finial_colors=(TOY_RED, MINT),
    )
    return m


def build_yard():
    """
    Trees, hedges and flower beds framing the garage (slot-origin pivot; layout cf = identity).

    Trees and side hedges are split into a -X ("L") and a +X ("R") piece. One piece per colour
    would have a bounding box spanning the whole lot, and the client's producer billboard placement
    (ProducerBillboards.place: Workspace:GetPartBoundsInBox over visible parts, owner R31/R32) and
    its ground raycast would treat the garage interior as "inside the trees" and shove the Garage
    Lab billboard out of the door (tests/billboard-clearance.luau). The back hedge stays one piece
    (its box stays behind the garage). +4 pieces.
    """
    m = Model("A1_Yard", SLOT_PIVOT, budget=3000)
    trunks = {-1: m.piece("TrunksL", BARK), 1: m.piece("TrunksR", BARK)}
    leaves = {-1: m.piece("LeavesL", LEAF), 1: m.piece("LeavesR", LEAF)}
    hedge = m.piece("Hedges", (58, 168, 66))
    side_hedges = {-1: m.piece("HedgesL", (58, 168, 66)), 1: m.piece("HedgesR", (58, 168, 66))}
    soil = m.piece("Soil", SOIL)
    stems = m.piece("Stems", (48, 140, 52), material="Smooth")
    red = m.piece("PetalsRed", TOY_RED, material="StudsSmall")
    yellow = m.piece("PetalsYellow", YELLOW, material="StudsSmall")
    pink = m.piece("PetalsPink", PINK, material="StudsSmall")
    for x, z, h, c in ((-42, 30, 9.0, 3.2), (-46, 56, 10.0, 3.4), (-26, 63, 8.5, 3.0), (44, 29, 9.5, 3.3), (46, 55, 8.0, 2.9), (28, 63, 10.0, 3.4)):
        side = -1 if x < 0 else 1
        round_tree(trunks[side], leaves[side], (x, LOT_TOP, z), height=h, crown=c)
    # Hedges: along the back edge and the back half of both sides.
    for x0, x1 in ((-50.5, -2.0), (2.0, 50.5)):
        block(hedge, ((x0 + x1) / 2, LOT_TOP + 1.1, 68.2), (x1 - x0, 2.2, 2.2), bevel=0.45, segments=2)
    for sx in (-1, 1):
        block(side_hedges[sx], (sx * 50.4, LOT_TOP + 1.1, 52.0), (2.2, 2.2, 30.0), bevel=0.45, segments=2)
    # Flower beds in front of the garage's two door pillars.
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 9.6, sx * 13.8))
        flower_bed(soil, stems, [red, yellow, pink], x0, x1, 28.6, 31.4)
    return m


def build_uncle_atom():
    """
    Uncle Atom (Area 1 Manager): kindly old inventor — white lab coat, green tie, bald head with
    white side tufts, bushy brows + big mustache, green-glow goggles on his forehead; left arm
    relaxed at his side and a little glowing pocket nuke held in his right.

    Animated NPC (owner R30): the figure is split into rig pieces (Torso*/Head*/ArmL*/ArmR*/LegL*/
    LegR*, see models/_npc_rig.py) so the client ManagerController can walk him, swing his limbs,
    wave (it raises the relaxed left arm) and play his work tap. Rest pose = arms relaxed.
    """
    from models._npc_rig import a1_bones, rig_split

    m = Model("A1_UncleAtom", "ground centre between his feet; faces -Z", budget=3000)
    coat = m.piece("Coat", WHITE)
    pants = m.piece("Pants", (70, 92, 160))
    shoes = m.piece("Shoes", CHARCOAL)
    skin = m.piece("Skin", SKIN, material="Smooth")
    face = m.piece("Face", (40, 36, 46), material="Smooth")
    cheeks = m.piece("Cheeks", (255, 150, 150), material="Smooth")
    hair = m.piece("Hair", (238, 240, 246), material="StudsSmall")
    tie = m.piece("Tie", LIME, material="StudsSmall")
    goggles = m.piece("Goggles", DARK_STEEL, material="StudsSmall")
    lens = m.piece("Lenses", GLOW_GREEN, material="Neon")
    a = toy_figure(
        {"shoes": shoes, "legs": pants, "torso": coat, "arms": coat, "skin": skin, "face": face, "cheeks": cheeks},
        left_arm=(12.0, 0.0),
        right_arm=(10.0, 55.0),
    )
    hip = a["hip"]
    # Lab-coat tails flaring over the legs + lapels + pocket.
    block(coat, (0, hip - 0.45, 0.02), (2.25, 1.0, 1.25), bevel=0.2)
    shirt_z = -0.6
    prism(tie, [(-0.22, hip + 1.95, shirt_z), (0.22, hip + 1.95, shirt_z), (0.3, hip + 0.7, shirt_z), (0.0, hip + 0.45, shirt_z), (-0.3, hip + 0.7, shirt_z)], (0, 0, 1), 0.12)
    block(tie, (0, hip + 2.0, shirt_z), (0.5, 0.3, 0.14), bevel=0.05)
    # Trefoil badge on the coat's left chest.
    revolve(hair, [(0.0, -0.04), (0.36, -0.04), (0.36, 0.04), (0.0, 0.04)], center=(-0.6, hip + 1.45, -0.6), segments=12, rot=rot_x(90))
    trefoil(face, (-0.6, hip + 1.45, -0.66), 0.28, 0.05)
    # Head details: side tufts, brows, mustache, round nose.
    hc = a["head"]
    hw, hh, hd = a["head_size"]
    for sx in (-1, 1):
        block(hair, (sx * (hw / 2 + 0.05), hc[1] - 0.05, 0.25), (0.55, 0.95, 1.2), bevel=0.2)
        block(hair, (sx * 0.42, hc[1] + 0.52, -hd / 2 - 0.06), (0.62, 0.2, 0.16), bevel=0.06)
    block(hair, (0, hc[1] - 0.5, 0.75), (1.6, 0.7, 0.4), bevel=0.15)  # back fringe
    for sx in (-1, 1):
        ellipsoid(hair, (sx * 0.34, hc[1] - 0.2, -hd / 2 - 0.12), (0.42, 0.2, 0.16), rings=4, segments=8)
    ellipsoid(skin, (0, hc[1] - 0.02, -hd / 2 - 0.12), (0.22, 0.2, 0.18), rings=4, segments=8)
    # Goggles pushed up on the forehead: strap ring + two round frames with glowing lenses.
    gy = hc[1] + hh / 2 - 0.2
    ring_tube(goggles, (0, gy, 0), hw / 2 + 0.06, 0.16, 0.3, segments=16)
    for sx in (-1, 1):
        revolve(goggles, [(0.0, -0.16), (0.36, -0.16), (0.36, 0.16), (0.0, 0.16)], center=(sx * 0.42, gy + 0.05, -hd / 2 - 0.18), segments=12, rot=rot_x(90))
        revolve(lens, [(0.0, -0.05), (0.26, -0.05), (0.26, 0.05), (0.0, 0.05)], center=(sx * 0.42, gy + 0.05, -hd / 2 - 0.36), segments=12, rot=rot_x(90))
    # Pocket nuke in his right hand.
    hx, hy, hz = a["hands"]["right"]
    nb = m.piece("NukeBody", TOY_RED, material="StudsSmall")
    mini_nuke(nb, coat, shoes, lens, (hx, hy + 0.25, hz), length=1.5, radius=0.36)
    # Body-part pieces for the client NPC rig (the pocket nuke rides the right hand).
    rig_split(m, a1_bones(a), assign={"NukeBody": "ArmR"})
    return m


def build_reactor_pack():
    """
    Coolant unit bolted to the garage wall (Mini Reactor upgrade, seen from outside): white box on
    a steel skid with a hazard band, a big glowing fan grille, two bubbling glass coolant tubes on
    top and steel pipes running back into the wall. Back (+Z) goes against the wall.
    """
    m = Model("A1_ReactorPack", "ground centre; back (+Z) flush against a wall; fan faces -Z", budget=3000)
    skid = m.piece("Skid", DARK_STEEL)
    body = m.piece("Body", WHITE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    steel = m.piece("Pipes", STEEL, material="StudsSmall")
    block(skid, (0, 0.2, -0.1), (5.0, 0.4, 3.2), bevel=0.1)
    block(body, (0, 2.0, 0), (4.4, 3.2, 2.8), bevel=0.3)
    hazard_band(yellow, black, (0, 0.85, -1.45), (4.2, 0.7, 0.16), stripe=0.5)
    # Fan grille: dark ring + glowing core + four chunky blades + hub.
    fy = 2.25
    ring_tube(skid, (0, fy, -1.45), 1.05, 0.28, 0.3, segments=18, axis="Z")
    # Glow disc stands 0.03 proud of the box front (z -1.43..-1.49): never flush (owner R18 z-fighting).
    revolve(glow, [(0.0, -0.03), (0.95, -0.03), (0.95, 0.03), (0.0, 0.03)], center=(0, fy, -1.46), segments=18, rot=rot_x(90))
    for k in range(4):
        ang = math.radians(20 + 90 * k)
        bx, by = 0.48 * math.cos(ang), 0.48 * math.sin(ang)
        box(skid, (bx, fy + by, -1.5), (0.9, 0.34, 0.1), rot=rot_z(math.degrees(ang)), bevel=0.04)
    disc(skid, (0, fy, -1.62), 0.25, 0.2, segments=10)
    # Trefoil badge top-left of the grille.
    block(yellow, (-1.65, 3.25, -1.43), (0.8, 0.8, 0.1), bevel=0.1)
    trefoil(black, (-1.65, 3.25, -1.5), 0.3, 0.05)
    # Two coolant tubes on top: glass shell, glowing liquid, steel caps.
    for x in (-1.0, 1.0):
        disc(steel, (x, 3.6, 0.2), 0.62, 0.25, segments=12, bevel=0.06)
        cylinder(glass, (x, 3.85, 0.2), (x, 5.45, 0.2), 0.52, segments=12)
        cylinder(glow, (x, 3.9, 0.2), (x, 5.0, 0.2), 0.4, segments=10)
        disc(steel, (x, 5.45, 0.2), 0.62, 0.3, segments=12, bevel=0.08)
        ellipsoid(glass, (x + 0.12, 4.4, 0.05), (0.1, 0.1, 0.1), rings=3, segments=6)
    # Pipes from the tube caps and the box back into the wall (+Z).
    pipe(steel, [(-1.0, 5.75, 0.2), (-1.0, 6.2, 0.2), (-1.0, 6.2, 1.9)], 0.16, segments=8)
    pipe(steel, [(1.0, 5.75, 0.2), (1.0, 6.4, 0.2), (1.0, 6.4, 1.9)], 0.16, segments=8)
    pipe(steel, [(1.6, 1.4, 1.2), (1.6, 1.4, 1.9)], 0.22, segments=8, joints=False)
    return m


def build_nuke_mobile():
    """
    The family "Nuke-Mobile": a chubby mint toy hatchback with headlight eyes, a grille smile,
    big wheels poking out and a pocket nuke mascot on a roof rack. Parked on the Driveway.
    """
    m = Model("A1_NukeMobile", "ground centre; nose faces -Z; roof rack top at y ~ 4.6", budget=3000)
    body = m.piece("Body", MINT)
    roof = m.piece("Roof", WHITE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.3)
    tyres = m.piece("Tyres", TYRE)
    hubs = m.piece("Hubs", STEEL, material="StudsSmall")
    bumpers = m.piece("Bumpers", CHARCOAL)
    lights = m.piece("Headlights", LAMP_WARM, material="Neon")
    tail = m.piece("Taillights", TOY_RED, material="Neon")
    rack = m.piece("Rack", DARK_STEEL, material="StudsSmall")
    nuke = m.piece("NukeBody", TOY_RED, material="StudsSmall")
    core = m.piece("NukeCore", GLOW_GREEN, material="Neon")
    r = 1.1
    for sx in (-1, 1):
        for sz in (-1, 1):
            wheel(tyres, hubs, (sx * 2.35, r, sz * 2.7), r, 1.0)
    block(body, (0, 1.75, 0), (4.9, 1.6, 8.2), bevel=0.45, segments=2)
    block(body, (0, 3.2, 0.5), (4.4, 1.5, 4.8), bevel=0.4, segments=2)
    block(roof, (0, 4.05, 0.5), (4.6, 0.35, 5.0), bevel=0.12)
    # Windows: windshield, rear window, two per side (glass panels just proud of the cabin).
    block(glass, (0, 3.25, -1.93), (3.7, 1.05, 0.1), bevel=0.03)
    block(glass, (0, 3.25, 2.93), (3.7, 1.0, 0.1), bevel=0.03)
    for sx in (-1, 1):
        for zc in (-0.55, 1.6):
            block(glass, (sx * 2.23, 3.25, zc), (0.1, 1.0, 1.8), bevel=0.03)
    # Face: headlight eyes, grille smile, bumpers.
    for sx in (-1, 1):
        revolve(lights, [(0.0, -0.08), (0.45, -0.08), (0.45, 0.08), (0.0, 0.08)], center=(sx * 1.45, 2.05, -4.12), segments=12, rot=rot_x(90))
        block(tail, (sx * 1.7, 2.1, 4.12), (0.8, 0.5, 0.12), bevel=0.05)
    pts_o, pts_i = [], []
    for k in range(9):
        a = math.radians(200 + 140 * k / 8)
        pts_o.append((0.95 * math.cos(a), 1.75 + 0.6 * math.sin(a), -4.14))
        pts_i.append((0.65 * math.cos(a), 1.75 + 0.35 * math.sin(a), -4.14))
    prism(bumpers, pts_o + list(reversed(pts_i)), (0, 0, 1), 0.1)
    for sz in (-1, 1):
        block(bumpers, (0, 0.95, sz * 4.15), (5.0, 0.55, 0.55), bevel=0.2)
    # Roof rack + upright pocket-nuke mascot.
    for sx in (-1, 1):
        bar(rack, (sx * 1.7, 4.35, -1.4), (sx * 1.7, 4.35, 2.4), 0.2)
    for zc in (-0.9, 1.9):
        bar(rack, (-1.8, 4.4, zc), (1.8, 4.4, zc), 0.18)
    block(rack, (0, 4.4, 0.5), (1.8, 0.2, 1.8), bevel=0.05)
    nuke_body(nuke, roof, bumpers, core, base=(0, 4.5, 0.5), length=2.6, radius=0.62, segments=12)
    return m


BUILDERS = {
    "A1_Lot": build_lot,
    "A1_EntryArch": build_arch,
    "A1_Yard": build_yard,
    "A1_UncleAtom": build_uncle_atom,
    "A1_ReactorPack": build_reactor_pack,
    "A1_NukeMobile": build_nuke_mobile,
}
