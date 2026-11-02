"""
dino_area03.py — Dino Valley area D3 "Ptero Post" (World 2 spec §6.2 / §16, owner R57): a treetop
nest tower where pterodactyl couriers fly pebble-nuke parcels in and out, a rope bridge to a lookout
tree, a woven landing pad, a striped wind sock, a perch of resting pteros and a treasure-map board.
Every pad purchase is its own model set so each one builds in separately; placement lives in
src/shared/Config/Worlds/Dino/Layouts/Area03.luau.

Also hosts the helpers dino_area04.py shares (palette, foliage, parcels, pebble nukes, balance).
Managers use W6's shared `dino_biped` / `dino_bones` (models/dino_area01.py), so all six Dino
managers have the same body; species details (beak, crest, bill, clothes) are added here.

Every model has its OWN pivot (ground centre unless stated, front = -Z). The layout places it with
a slot-local CFrame (slot +Z points away from the road, so identity rotation faces the road); models
standing on the area floor are placed at y = 0.4 (floor top).

Models (key: pivot / notes)                                       build key
    D3_Floor          slab centre at ground; top y = 0.4              base
    D3_EntryArch      ground centre of the walkway opening; double-   base
                      sided "PTERO / POST" block letters (R17)
    D3_Jungle         slot origin on the floor top (placed at          base
                      (0, 0.4, 0)); back palms, boulders, ferns
    D3_NestTower      PRODUCER "Ptero Express": giant tree trunk,      D3_NestTower
                      twig nest deck, spiral bamboo parcel chute,
                      sorting counter; pivot = trunk base centre
    D3_PteroCourier   ROUTED flyer (R56): Body / WingL / WingR /       D3_NestTower (x2, perched)
                      Parcel (+ ParcelTie); pivot = parcel bottom
    D3_RopeBridge     lookout tree + rope bridge running toward +X     D3_RopeBridge
                      to the nest rim; pivot = lookout trunk base
    D3_ParcelBaskets  two wicker baskets + parcel stack                D3_ParcelBaskets (x2)
    D3_WindSock       bamboo pole + swivelling striped sock            D3_WindSock
    D3_PteroFlock     three perched pteros on a driftwood perch        D3_PteroFlock
    D3_TreasureMap    parchment map board on two log posts             D3_TreasureMap
    D3_LandingPad     woven landing deck on a stone ring               D3_LandingPad
    D3_CaptainPtera   Manager NPC figure ONLY (R30 rig groups)         D3_CaptainPtera

Animation contract (piece names; rows are W10's WorldFxConfig / VehicleRoutes work):
    Sock / SockStripes   D3_WindSock: swing about local Y. Both pieces' bounding boxes are centred on
                         the pole axis (the counter-vane mirrors the sock), so an oscillation about
                         the piece centre turns the sock round the pole.
    WingL / WingR        D3_PteroCourier: flap about local Z. Each wing is balanced (one 0.04 cube
                         hidden inside the opposite wing) so its box centre sits on the body centre
                         line (0, WING_Y, z); the routed model is never moved by WorldFx (R25), so
                         flapping needs a VehicleRoutes hook.
    Parcel / ParcelTie   D3_PteroCourier cargo (route `cargo` groups pop it on / off).
    Static on purpose: "Lanterns" (Smooth soft glow, R19), "Amber*" pebble-nuke cores (small Neon,
    no FX word so they never bob off their pebble).

Glow budget (owner R19): Neon only on pebble-nuke cores (one small piece per nuke, < 1 stud²).
Everything else that "glows" (lanterns) is Smooth AMBER_SOFT.

Budgets: floor <= 2,500, arch <= 4,500, jungle backdrop <= 4,500, producer (hero) <= 6,000, props <= 2,500,
flyer <= 1,500, manager <= 2,500. A fully built D3 stays <= 28k triangles (spec §15).
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import WHITE, Model
from snkit.kit import block, disc, sign_frame
from snkit.shapes import bar, box, cylinder, ellipsoid, frame_from, loft, prism, revolve, ring_tube, rot_x, rot_y, rot_z

from models._critter_kit import oriented_ellipsoid, surface, tube
from models.area01 import block_text, sign_text
from models.area04 import Xf, _hash
from models.dino_area01 import dino_biped, dino_bones  # W6's shared manager body (same proportions in every Dino area)

# ------------------------------------------------------------------------------------------------
# Dino Valley palette (spec §2: fern green / sand / mossy stone / amber orange / bone cream / candy
# lava; organic round shapes, thatch, logs, bamboo, rope; no grey metal or hazard stripes).
# ------------------------------------------------------------------------------------------------

FERN = (104, 190, 84)  # jungle-floor grass
FERN_DARK = (66, 150, 70)  # leaf-litter patches, fern tufts
JUNGLE = (52, 140, 80)  # deep canopy / palm fronds
LEAF_LIGHT = (156, 214, 96)  # sunlit canopy tops
SAND = (240, 212, 156)  # sandy paths
SAND_DARK = (218, 182, 122)
STONE = (186, 178, 160)  # warm mossy stone
STONE_DARK = (150, 142, 128)
MOSS = (128, 176, 88)
BARK = (160, 108, 68)
BARK_DARK = (120, 80, 52)
THATCH = (230, 192, 112)  # woven nests, baskets, decks
BAMBOO = (196, 210, 104)
BAMBOO_DARK = (150, 170, 72)
ROPE = (226, 196, 140)
BONE = (248, 236, 210)  # bone cream: boards, bellies, parchment
AMBER = (255, 170, 44)  # pebble-nuke cores (small Neon)
AMBER_SOFT = (255, 206, 120)  # large soft glows, rendered Smooth (R19)
LAVA = (255, 124, 44)  # candy lava / accents
PARCEL = (222, 168, 104)  # kraft-paper parcels
WATER = (118, 202, 238)
WATER_LIGHT = (176, 228, 248)
PEBBLE = (176, 168, 184)  # lavender-grey river pebble (the nuke shell)
EYE = (40, 36, 48)
BEAK = (255, 204, 70)
SCARF = (236, 82, 70)  # neckerchiefs, ties
NAVY = (46, 64, 124)
PTERO_TEAL = (76, 190, 200)
PTERO_CORAL = (255, 140, 96)
PTERO_LILAC = (176, 140, 230)
WING_TEAL = (138, 214, 220)
WING_CORAL = (255, 186, 150)
LETTER_TEAL = (30, 112, 128)  # Smooth block letters on bone boards (not Neon: R19)
INK_RED = (214, 58, 52)
INK_BLUE = (64, 132, 210)
INK_GREEN = (58, 150, 72)
INK_BROWN = (138, 92, 56)

FLOOR_TOP = 0.4  # area floor top; models standing on the floor are placed at y = FLOOR_TOP
SLOT_W = 104.0
SLOT_D = 70.0


# ------------------------------------------------------------------------------------------------
# Shared Dino helpers (also imported by dino_area04.py)
# ------------------------------------------------------------------------------------------------

# Leaf outlines: (t along the leaf 0..1, half-width as a fraction of `width`), mirrored.
FERN_BLADE = ((0.0, 0.10), (0.35, 0.50), (0.75, 0.32), (1.0, 0.0))
FROND_INNER = ((0.0, 0.12), (0.45, 0.50), (1.0, 0.42))
FROND_OUTER = ((0.0, 0.42), (0.5, 0.40), (1.0, 0.0))


def leaf(piece, base, direction, length: float, width: float, shape=FERN_BLADE, thickness: float = 0.12):
    """
    One flat leaf / frond blade: a planar outline laid along `direction` from `base`, widest across
    the horizontal side vector, extruded `thickness` along the leaf's face normal. Planar on purpose
    (prism needs a flat outline); bent fronds are two leaves joined end to end (see `palm`).

    Example: leaf(fronds, (0, 8, 0), (1, 0.3, 0), 3.0, 1.2)   # a blade pointing +X and slightly up
    """
    d = Vector(direction).normalized()
    side = Vector((-d.z, 0.0, d.x))
    if side.length < 1e-4:
        side = Vector((1.0, 0.0, 0.0))
    side.normalize()
    normal = d.cross(side).normalized()
    b = Vector(base)
    right = [b + d * (t * length) + side * (w * width) for t, w in shape]
    left = [b + d * (t * length) - side * (w * width) for t, w in reversed(shape)]
    pts = right + left
    # Drop the duplicated tip / root point when the outline closes to zero width there.
    outline = []
    for p in pts:
        if not outline or (p - outline[-1]).length > 1e-4:
            outline.append(p)
    if (outline[0] - outline[-1]).length <= 1e-4:
        outline.pop()
    prism(piece, [(p.x, p.y, p.z) for p in outline], (normal.x, normal.y, normal.z), thickness)


def fern(piece, base, scale: float = 1.0, seed: int = 0, blades: int = 5):
    """
    Fern / grass tuft: `blades` leaf blades radiating from `base`, tilted 40-60 degrees up (~24
    triangles each). Deterministic per seed (no random state: piece hashes must stay stable).

    Example: fern(ferns, (12, 0, 4), scale=1.2, seed=3)
    """
    bx, by, bz = base
    for i in range(blades):
        a = 2 * math.pi * (i + _hash(seed, i) * 0.6) / blades
        tilt = math.radians(38 + 22 * _hash(seed + 3, i))
        d = (math.cos(a) * math.cos(tilt), math.sin(tilt), math.sin(a) * math.cos(tilt))
        length = scale * (1.6 + 0.8 * _hash(seed + 5, i))
        leaf(piece, (bx, by - 0.05, bz), d, length, scale * 0.55)


def palm(trunk, fronds, nuts, base, height: float = 11.0, lean=(1.0, 0.0), seed: int = 0, frond_len: float = 5.0, count: int = 5):
    """
    Toy palm tree: three stacked, slightly leaning trunk frustums (the overlaps read as the ringed
    palm trunk), a crown ball, `count` two-part fronds (rising inner blade + drooping outer blade)
    and two coconuts. ~220 triangles. `lean` = (dx, dz) of the crown relative to the base.

    Example: palm(trunks, fronds, nuts, (-20, 0, 64), height=12, lean=(-1.2, 0.4), seed=2)
    """
    bx, by, bz = base
    lx, lz = lean
    pts = []
    for k in range(4):
        t = k / 3
        pts.append((bx + lx * t * t, by + height * t, bz + lz * t * t))
    for k in range(3):
        r0 = 0.62 - 0.1 * k
        cylinder(trunk, pts[k], (pts[k + 1][0], pts[k + 1][1] + 0.25, pts[k + 1][2]), r0, segments=7, radius_b=r0 * 0.78)
    top = pts[3]
    ellipsoid(fronds, (top[0], top[1] + 0.3, top[2]), (0.9, 0.7, 0.9), rings=4, segments=7)
    for c in range(2):
        a = 2.1 * c + seed
        ellipsoid(nuts, (top[0] + 0.55 * math.cos(a), top[1] - 0.35, top[2] + 0.55 * math.sin(a)), (0.32, 0.32, 0.32), rings=3, segments=6)
    for i in range(count):
        a = 2 * math.pi * (i + 0.35 * _hash(seed, i)) / count
        out = Vector((math.cos(a), 0.0, math.sin(a)))
        inner_dir = out * math.cos(math.radians(18)) + Vector((0, math.sin(math.radians(18)), 0))
        start = Vector((top[0], top[1] + 0.4, top[2]))
        inner_len = frond_len * 0.48
        leaf(fronds, tuple(start), tuple(inner_dir), inner_len, 1.25, shape=FROND_INNER)
        joint = start + inner_dir.normalized() * inner_len
        droop = math.radians(32 + 14 * _hash(seed + 2, i))
        outer_dir = out * math.cos(droop) - Vector((0, math.sin(droop), 0))
        leaf(fronds, tuple(joint), tuple(outer_dir), frond_len * 0.56, 1.25, shape=FROND_OUTER)


def boulder(piece, center, radii, seed: int = 0, rings: int = 4, segments: int = 7, floor: float | None = None):
    """
    Chunky rounded rock: a low-poly ellipsoid with a deterministic lumpy deform (~42 triangles).
    `center` is the ellipsoid centre. Pass `floor` (the model-space y of the ground it stands on)
    for floor-standing rocks: every vertex below floor - 0.1 is flattened onto that plane, so the
    rock looks half-buried yet never cuts more than 0.1 into the floor slab (owner R24, 0.2 limit).

    Example: boulder(rocks, (30, 0.6, 66), (2.4, 1.6, 2.0), seed=4, floor=0.0)
    """
    cy = center[1]
    lowest = None if floor is None else floor - 0.1 - cy

    def lumpy(x, y, z):
        k = 1.0 + 0.16 * (_hash(seed + x * 3.1, z * 2.3 + y) - 0.5)
        yy = y * (0.92 + 0.08 * k)
        if lowest is not None and yy < lowest:
            yy = lowest
        return (x * k, yy, z * k)

    ellipsoid(piece, center, radii, rings=rings, segments=segments, deform=lumpy)


def parcel(box_piece, tie_piece, center, size, yaw: float = 0.0, bow: bool = True):
    """
    Toy parcel: a chunky kraft box with a vine tie crossing over it (two bands, the second 0.02
    taller so their top faces never share a plane: R18) and an optional bow knot on top.

    Example: parcel(parcels, ties, (0, 0.6, 0), (1.4, 1.2, 1.2), yaw=15)
    """
    rot = rot_y(yaw)
    cx, cy, cz = center
    sx, sy, sz = size
    block(box_piece, center, size, bevel=0.08, rot=rot)
    box(tie_piece, center, (sx + 0.1, sy + 0.1, 0.24), rot=rot)
    box(tie_piece, center, (0.24, sy + 0.14, sz + 0.1), rot=rot)
    if bow:
        for s in (-1, 1):
            off = rot @ Vector((s * 0.22, 0.0, 0.0))
            box(tie_piece, (cx + off.x, cy + sy / 2 + 0.16, cz + off.z), (0.34, 0.2, 0.2), rot=rot @ rot_z(s * 25))


def pebble_nuke(stone, glow, fins, base, scale: float = 1.0, yaw: float = 0.0):
    """
    The Dino Valley product: a "pebble nuke" carved from a river pebble — an egg-round stone body,
    a glowing amber core band (pass a SMALL Neon piece, one per nuke, so it stays a Neon accent:
    R19) and three stubby stone fins. base = bottom centre. ~150 triangles.

    Example: pebble_nuke(pebbles, m.piece("AmberL", AMBER, material="Neon"), fins, (2, 3.0, -9))
    """
    bx, by, bz = base
    s = scale
    ellipsoid(stone, (bx, by + 0.78 * s, bz), (0.6 * s, 0.74 * s, 0.6 * s), rings=5, segments=8)
    ring_tube(glow, (bx, by + 0.8 * s, bz), 0.6 * s, 0.14 * s, 0.24 * s, segments=8)
    for k in range(3):
        a = math.radians(yaw + 90 + 120 * k)
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        r0 = d * (0.32 * s)
        r1 = d * (0.78 * s)
        outline = [
            (bx + r0.x, by + 0.12 * s, bz + r0.z),
            (bx + r1.x, by + 0.02 * s, bz + r1.z),
            (bx + r1.x * 0.8, by + 0.38 * s, bz + r1.z * 0.8),
            (bx + r0.x, by + 0.62 * s, bz + r0.z),
        ]
        side = (-d.z, 0.0, d.x)
        prism(fins, outline, side, 0.16 * s)


def basket(wicker, band, center, radius: float, height: float, segments: int = 10):
    """
    Open woven basket (bottom centre = `center`): a hollow revolve (outer wall, rim lip, inner wall,
    inner floor), a rim ring proud of the lip on every side and one weave band proud of the wall.

    Example: basket(wicker, bands, (0, 0, 0), 1.4, 1.5)
    """
    cx, cy, cz = center
    r0 = radius * 0.78
    revolve(
        wicker,
        [(0.0, 0.0), (r0, 0.0), (radius, height), (radius - 0.16, height), (r0 - 0.12, 0.22), (0.0, 0.22)],
        center=(cx, cy, cz),
        segments=segments,
    )
    ring_tube(band, (cx, cy + height, cz), radius - 0.08, 0.32, 0.24, segments=segments)
    mid = 0.45
    r_mid = r0 + (radius - r0) * mid
    ring_tube(band, (cx, cy + height * mid, cz), r_mid + 0.06, 0.16, 0.22, segments=segments)


def balance(piece, pivot, axes=(0, 1), free=(0.0, 0.0, 0.0)):
    """
    Adds ONE 0.04-stud cube so the piece's bounding-box centre lands on `pivot` along `axes`
    (0 = X, 1 = Y, 2 = Z). Roblox puts a MeshPart's CFrame at its box centre and the client turns
    moving pieces about it, so a hinged piece (a wing) needs its box mirrored around the hinge.
    Place `free` so the cube hides inside other geometry. Same idea as hub_plaza.balance_about.

    Example: balance(wing_r, (0.0, 2.6, 0.0), axes=(0,), free=(0, 2.6, 0.2))
    """
    from snkit.core import br

    pts = [br(v.co) for v in piece.bm.verts]
    lo = [min(p[i] for p in pts) for i in range(3)]
    hi = [max(p[i] for p in pts) for i in range(3)]
    cube = list(free)
    for i in axes:
        mid = (lo[i] + hi[i]) / 2
        cube[i] = 2 * pivot[i] - (lo[i] if pivot[i] > mid else hi[i])
    box(piece, tuple(cube), (0.04, 0.04, 0.04))


# ------------------------------------------------------------------------------------------------
# Shared arch helper (posts + header + double-sided sign); D3 / D4 dress it differently.
# ------------------------------------------------------------------------------------------------


def arch_sign(frame_piece, board_piece, letters_piece, lines, center, size, cell: float):
    """
    Double-sided arch sign (owner R17): framed bone board + block letters on BOTH faces, readable
    from the road (-Z) and from inside the area (+Z). Frame bars are 0.15 proud of the board (R18).

    Example: arch_sign(frame, board, letters, ["PTERO", "POST"], (0, 20.2, 0), (12.6, 6.2), 0.3)
    """
    depth = 0.7
    sign_frame(frame_piece, board_piece, center, size, border=0.6, depth=depth)
    sign_text(letters_piece, lines, center, cell, 0.2, depth * 0.35)


# ------------------------------------------------------------------------------------------------
# Base: floor, entry arch, jungle backdrop
# ------------------------------------------------------------------------------------------------


def build_floor():
    """Jungle-grass slab for the whole slot, a sandy stepping-slab walkway from the road to the
    sorting counter, a side path to the landing pad and leaf-litter patches (none overlapping)."""
    m = Model("D3_Floor", "slab centre at ground (place at slot (0, 0, 35)); top y = 0.4", budget=2500)
    grass = m.piece("Grass", FERN)
    patch = m.piece("Patch", FERN_DARK)
    path = m.piece("Path", SAND)
    # Full slot width (x +-52): neighbouring floors butt edge to edge (areas-art "Slot-edge floors").
    block(grass, (0, FLOOR_TOP / 2, 0), (SLOT_W, FLOOR_TOP, SLOT_D - 0.4), bevel=0.15)
    # Leaf-litter patches (flat, raised 0.1): spread so no two overlap (equal tops would z-fight).
    for i, (x, z, sx, sz) in enumerate(
        ((-30, -22, 12, 7), (24, -24, 10, 6), (-40, 6, 9, 8), (38, 2, 8, 9), (-20, 16, 10, 7), (18, 22, 9, 6), (-42, 26, 8, 6), (34, 27, 8, 5))
    ):
        block(patch, (x, FLOOR_TOP + 0.04, z), (sx, 0.12, sz), bevel=0.04, rot=rot_y(20 * (_hash(i, 2) - 0.5)))
    # Stepping-slab walkway: road edge (z = -35) to the counter front (slot z 39.3 -> local 4.3).
    z = -34.6
    k = 0
    while z < 3.9:
        length = min(2.8 + 1.0 * _hash(k, 4), 4.2 - z)
        if length < 0.8:
            break
        off = 0.5 * (_hash(k, 6) - 0.5)
        for s in (-1, 1):
            block(path, (s * 2.6 + off, FLOOR_TOP + 0.08, z + length / 2), (4.6, 0.2, length - 0.4), bevel=0.08)
        z += length
        k += 1
    # Side path to the landing pad (slot x 6..20 at slot z ~31 -> local z -4).
    x = 6.2
    k = 0
    while x < 20.5:
        length = 2.6 + 0.8 * _hash(k, 9)
        block(path, (x + length / 2, FLOOR_TOP + 0.08, -4.0 + 0.4 * (_hash(k, 11) - 0.5)), (length - 0.4, 0.2, 3.2), bevel=0.08)
        x += length
        k += 1
    return m


ARCH_SIGN_Y = 20.2  # sign board centre (bottom edge 17.1, clear of the upper header log)


def build_entry_arch():
    """Two log posts with rope lashings and leaf crowns, a double log header, the "PTERO / POST"
    board (double-sided, R17) with a parcel on top, and fern tufts at the post feet. Opening 14.8
    wide x 13.6 high."""
    m = Model("D3_EntryArch", "ground centre of the walkway opening; double-sided sign, front -Z (road)", budget=4500)
    logp = m.piece("Logs", BARK)
    dark = m.piece("LogsDark", BARK_DARK)
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    leaves = m.piece("Leaves", JUNGLE)
    ferns = m.piece("Ferns", FERN_DARK)
    board = m.piece("Board", BONE, material="Smooth")
    letters = m.piece("Letters", LETTER_TEAL, material="Smooth")
    box_p = m.piece("Parcel", PARCEL, material="StudsSmall")
    tie = m.piece("Tie", SCARF, material="StudsSmall")
    for s in (-1, 1):
        x = s * 9.2
        cylinder(logp, (x, 0, 0), (x, 1.3, 0), 2.0, segments=10, radius_b=1.5)  # root flare
        cylinder(logp, (x, 1.2, 0), (x, 8.0, 0), 1.5, segments=10, radius_b=1.38)
        cylinder(logp, (x, 7.9, 0), (x, 15.2, 0), 1.38, segments=10, radius_b=1.2)
        for y, r in ((3.0, 1.5), (12.8, 1.3)):
            ring_tube(rope, (x, y, 0), r + 0.06, 0.3, 0.5, segments=10)
        # Leaf crown: a bush ball + five drooping fronds.
        ellipsoid(leaves, (x, 15.6, 0), (1.6, 1.0, 1.6), rings=4, segments=8)
        for i in range(5):
            a = 2 * math.pi * (i + 0.3) / 5
            out = Vector((math.cos(a), 0.0, math.sin(a)))
            d = out * math.cos(math.radians(30)) - Vector((0, math.sin(math.radians(30)), 0))
            leaf(leaves, (x + out.x * 0.8, 15.7, out.z * 0.8), tuple(d), 3.4, 1.1, shape=FROND_OUTER)
        for k, (fx, fz) in enumerate(((s * 11.8, -1.4), (s * 11.2, 1.8))):
            fern(ferns, (fx, 0, fz), scale=1.1, seed=k + (5 if s > 0 else 0), blades=5)
    # Header: lower log across the posts + a thinner upper log (logs lashed across the posts).
    cylinder(logp, (-11.0, 14.4, 0), (11.0, 14.4, 0), 0.9, segments=10)
    cylinder(dark, (-10.2, 16.2, 0.25), (10.2, 16.2, 0.25), 0.7, segments=10)
    for x in (-4.6, 4.6):
        bar(dark, (x, 16.6, 0), (x, 17.5, 0), 0.4)
    arch_sign(dark, board, letters, ["PTERO", "POST"], (0, ARCH_SIGN_Y, 0), (12.6, 6.2), 0.3)
    parcel(box_p, tie, (0, ARCH_SIGN_Y + 3.1 + 0.6, 0), (1.8, 1.2, 1.4), yaw=8)
    return m


def build_jungle():
    """Back-row palms, boulders and ferns (slot space, pivot = slot origin on the floor top).
    Every piece stays clear of the producer billboard spot (R31): back items sit at z >= 44 (fronds
    reach z >= 38.5); side ferns nearer the road live in their own FernsL / FernsR pieces."""
    m = Model("D3_Jungle", "slot origin on the floor top (place at slot (0, 0.4, 0)); slot-space coordinates", budget=4500)
    trunks = m.piece("Trunks", BARK)
    fronds = m.piece("Fronds", JUNGLE)
    nuts = m.piece("Coconuts", BARK_DARK)
    rocks = m.piece("Rocks", STONE)
    moss = m.piece("Moss", MOSS)
    ferns = m.piece("Ferns", FERN_DARK)
    ferns_l = m.piece("FernsL", FERN_DARK)
    ferns_r = m.piece("FernsR", FERN_DARK)
    for i, (x, z, h, lx, lz) in enumerate(
        ((-44, 63, 12.5, -1.0, 0.5), (-21, 64.5, 14.0, 0.8, 0.6), (20, 65, 13.0, -0.9, 0.5), (43, 63, 11.5, 1.0, 0.4), (44, 46, 10.5, 0.8, -0.4), (-44, 48, 11.0, -0.6, -0.6))
    ):
        palm(trunks, fronds, nuts, (x, -0.1, z), height=h, lean=(lx, lz), seed=i, frond_len=5.0)
    for i, (x, z, rx, ry, rz) in enumerate(
        ((-34, 66.5, 2.6, 1.8, 2.2), (-8, 67, 2.2, 1.5, 2.0), (7, 66.5, 2.8, 2.0, 2.4), (31, 67, 2.4, 1.7, 2.0), (-12, 61, 1.5, 1.1, 1.4), (13, 60.5, 1.6, 1.2, 1.4))
    ):
        boulder(rocks, (x, ry * 0.5, z), (rx, ry, rz), seed=i, floor=0.0)
        if i < 4:
            boulder(moss, (x + 0.2 * rx, ry * 1.25, z - 0.1 * rz), (rx * 0.7, ry * 0.35, rz * 0.65), seed=i + 20)
    for i, (x, z) in enumerate(((-38, 58), (-27, 60), (-15, 66), (-2, 63), (11, 63), (26, 61), (38, 58), (48, 54), (-48, 56))):
        fern(ferns, (x, 0, z), scale=1.15, seed=i + 40)
    for i, z in enumerate((22.0, 31.0, 40.0)):
        fern(ferns_l, (48.5, 0, z), scale=1.0, seed=i + 60)
        fern(ferns_r, (-48.5, 0, z + 3.0), scale=1.0, seed=i + 70)
    return m


# ------------------------------------------------------------------------------------------------
# D3_NestTower — producer "Ptero Express"
# ------------------------------------------------------------------------------------------------

NEST_FLOOR = 20.2  # nest deck floor (inside the bowl), local y
NEST_RIM_R = 8.7  # rim ring centre radius (ring spans 8.25 .. 9.15)
NEST_RIM_Y = 21.0
CHUTE_R = 5.4  # spiral chute centre radius
CHUTE_TOP = 17.6  # chute start height (under the nest bowl)
CHUTE_END = 4.9  # chute end height (front of the trunk)
COUNTER_Z = -9.6  # sorting counter centre, local z
COUNTER_TOP = 3.0


def trunk_radius(y: float) -> float:
    """Nest-tower trunk radius at height y (matches the frustums in build_nest_tower)."""
    if y < 2.5:
        return 4.4 - (4.4 - 3.4) * max(0.0, y) / 2.6
    if y < 10.15:
        return 3.4 - 0.4 * (y - 2.5) / 7.7
    return 3.0 - 0.4 * min(1.0, (y - 10.1) / 8.9)


def _chute_section(center: Vector, radial: Vector, up: Vector):
    """U-channel cross-section (8 points, closed) at `center`: radial = across, up = channel up."""
    prof = [(-0.85, 0.7), (-0.85, -0.12), (0.85, -0.12), (0.85, 0.7), (0.62, 0.7), (0.62, 0.1), (-0.62, 0.1), (-0.62, 0.7)]
    return [tuple(center + radial * a + up * b) for a, b in prof]


def build_nest_tower():
    """
    Producer "Ptero Express": a giant tree trunk (root fins, bark plates, "POST" board) carrying a
    woven twig nest deck at y 20 and a leafy canopy; a bamboo parcel chute spirals once round the
    trunk from under the nest down to a log sorting counter in front, where a basket catches the
    parcels next to two glowing pebble nukes. A rope ladder hangs from the nest rim at the back.
    """
    m = Model("D3_NestTower", "trunk base centre on the floor; counter + chute exit face -Z (road)", budget=6000)
    bark = m.piece("Bark", BARK)
    bark_dark = m.piece("BarkDark", BARK_DARK)
    nest = m.piece("Nest", THATCH)
    twigs = m.piece("Twigs", BARK_DARK, material="StudsSmall")
    canopy = m.piece("Canopy", JUNGLE)
    canopy_top = m.piece("CanopyTop", LEAF_LIGHT)
    chute = m.piece("Chute", BAMBOO)
    bands = m.piece("ChuteBands", BAMBOO_DARK, material="StudsSmall")
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    board = m.piece("Board", BONE, material="Smooth")
    letters = m.piece("Letters", LETTER_TEAL, material="Smooth")
    parcels = m.piece("Parcels", PARCEL, material="StudsSmall")
    ties = m.piece("Ties", SCARF, material="StudsSmall")
    pebbles = m.piece("Pebbles", PEBBLE, material="StudsSmall")
    wicker = m.piece("Wicker", THATCH, material="StudsSmall")
    amber_l = m.piece("AmberL", AMBER, material="Neon")
    amber_r = m.piece("AmberR", AMBER, material="Neon")

    # Trunk: root flare + two tapering frustums + the thin top running up into the canopy.
    cylinder(bark, (0, 0, 0), (0, 2.6, 0), 4.4, segments=10, radius_b=3.4)
    cylinder(bark, (0, 2.5, 0), (0, 10.2, 0), 3.4, segments=10, radius_b=3.0)
    cylinder(bark, (0, 10.1, 0), (0, 19.0, 0), 3.0, segments=10, radius_b=2.6)
    cylinder(bark, (0, 18.9, 0), (0, 29.5, 0), 1.5, segments=8, radius_b=1.1)
    # Root fins (skip the front, where the counter stands).
    for k, deg in enumerate((60, 130, 180, 230, 300)):
        a = math.radians(deg)
        d = Vector((math.sin(a), 0.0, -math.cos(a)))
        outline = [tuple(d * 3.2 + Vector((0, 3.4, 0))), tuple(d * 3.2 + Vector((0, 0.02, 0))), tuple(d * (6.0 + 0.5 * _hash(k, 1)) + Vector((0, 0.02, 0)))]
        prism(bark, outline, (-d.z, 0.0, d.x), 1.1)
    # Bark plates on the trunk's flat faces (10-sided: vertices every 36 deg from the front, so face
    # centres sit at 18 + 36k deg, 0.951 r out), 0.3 proud of the face (R18: never flush).
    for k in range(14):
        a = math.radians(18 + 36 * (k % 10))
        y = 3.6 + 13.0 * _hash(k, 5)
        if (k % 10 in (0, 9)) and 10.0 < y < 14.6:
            y -= 5.0  # keep the POST board's spot clear (front faces)
        r = 0.951 * trunk_radius(y) + 0.12
        radial = Vector((math.sin(a), 0.0, -math.cos(a)))
        tangent = Vector((math.cos(a), 0.0, math.sin(a)))
        block(bark_dark, tuple(radial * r + Vector((0, y, 0))), (0.6, 2.2, 0.36), bevel=0.08, rot=frame_from(tangent, Vector((0, 1, 0))))
    # "POST" board on the trunk front (front-only lettering).
    sign_frame(bark_dark, board, (0, 12.2, -3.75), (5.8, 2.4), border=0.4, depth=0.5)
    block_text(letters, "POST", (0, 12.2, -3.75 - 0.175), 0.2, 0.16)
    for x in (-1.9, 1.9):
        bar(bark_dark, (x, 12.2, -3.5), (x, 12.2, -1.9), 0.3)

    # Nest bowl (outer wall, rim lip, inner slope, deck floor) + twig rim + poking twigs.
    revolve(
        nest,
        [(0.0, 18.6), (5.0, 18.6), (8.0, 19.6), (9.0, NEST_RIM_Y), (8.4, NEST_RIM_Y), (7.6, NEST_FLOOR), (0.0, NEST_FLOOR)],
        segments=16,
    )
    ring_tube(twigs, (0, NEST_RIM_Y, 0), NEST_RIM_R, 0.9, 0.8, segments=16)
    for k in range(18):
        a = 2 * math.pi * (k + 0.4 * _hash(k, 7)) / 18
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        y = 19.2 + 1.2 * _hash(k, 8)
        # Bowl outer radius at that height (profile: r 5 -> 8 over y 18.6 -> 19.6, then 8 -> 9 to the lip).
        rr = 5.0 + (y - 18.6) * 3.0 if y <= 19.6 else 8.0 + (y - 19.6) / 1.4
        inner = d * (rr - 0.5) + Vector((0, y, 0))
        tangent = Vector((-d.z, 0.0, d.x)) * (0.9 * (_hash(k, 9) - 0.5))
        outer = d * (rr + 1.3) + Vector((0, y + 0.3 * (_hash(k, 10) - 0.4), 0)) + tangent
        bar(twigs, tuple(inner), tuple(outer), 0.2)
    # Parcel pile on the deck (back of the nest).
    for k, (x, z, yaw) in enumerate(((-1.6, 4.4, 10), (1.1, 4.8, -20), (-0.2, 5.2, 35))):
        y = NEST_FLOOR + 0.55 + (1.15 if k == 2 else 0.0)
        parcel(parcels, ties, (x, y, z + (-0.6 if k == 2 else 0.0)), (1.5, 1.1, 1.3), yaw=yaw)

    # Canopy over the nest.
    for c, r in (((0, 30.2, 0), (6.6, 3.0, 6.6)), ((4.6, 28.4, 2.4), (4.0, 2.4, 4.0)), ((-4.6, 28.6, 1.6), (4.2, 2.4, 3.8)), ((0.6, 28.2, -4.2), (3.8, 2.2, 3.6))):
        ellipsoid(canopy, c, r, rings=5, segments=10)
    ellipsoid(canopy_top, (1.0, 32.6, 0.6), (3.8, 1.5, 3.8), rings=4, segments=10)

    # Spiral parcel chute: one full turn from the front under the nest (CHUTE_TOP) down to the
    # front again (CHUTE_END), then a straight exit trough over the counter basket.
    sections = []
    steps = 20
    for i in range(steps + 1):
        t = i / steps
        phi = 2 * math.pi * (1 - t)
        y = CHUTE_TOP + (CHUTE_END - CHUTE_TOP) * t
        c = Vector((CHUTE_R * math.sin(phi), y, -CHUTE_R * math.cos(phi)))
        radial = Vector((math.sin(phi), 0.0, -math.cos(phi)))
        sections.append(_chute_section(c, radial, Vector((0, 1, 0))))
    loft(chute, sections)
    exit_a = Vector((0.0, CHUTE_END, -CHUTE_R))
    exit_b = Vector((0.0, CHUTE_END - 0.35, COUNTER_Z + 1.25))
    loft(chute, [_chute_section(exit_a + Vector((0, 0, 0.3)), Vector((1, 0, 0)), Vector((0, 1, 0))), _chute_section(exit_b, Vector((1, 0, 0)), Vector((0, 1, 0)))])
    for i in range(0, steps, 4):
        t = (i + 2) / steps
        phi = 2 * math.pi * (1 - t)
        y = CHUTE_TOP + (CHUTE_END - CHUTE_TOP) * t
        c = Vector((CHUTE_R * math.sin(phi), y, -CHUTE_R * math.cos(phi)))
        # Bamboo band round the channel (proud of every face) + a bracket back to the trunk.
        inward = Vector((math.sin(phi), 0.0, -math.cos(phi)))
        box(bands, tuple(c + Vector((0, 0.29, 0))), (2.0, 1.1, 0.34), rot=frame_from(inward, Vector((0, 1, 0))))
        trunk_r = 0.951 * trunk_radius(y)
        bar(bark_dark, tuple(inward * (trunk_r - 0.3) + Vector((0, y - 0.9, 0))), tuple(c + Vector((0, -0.2, 0)) - inward * 0.3), 0.32)

    # Sorting counter: two stumps + a plank top, a basket under the chute exit, pebble nukes.
    for x in (-3.8, 3.8):
        cylinder(bark, (x, 0, COUNTER_Z), (x, COUNTER_TOP - 0.55, COUNTER_Z), 0.9, segments=10)
    block(bark_dark, (0, COUNTER_TOP - 0.3, COUNTER_Z), (10.0, 0.6, 2.2), bevel=0.15)
    basket(wicker, twigs, (0, COUNTER_TOP, COUNTER_Z + 0.15), 1.05, 1.0, segments=10)
    parcel(parcels, ties, (-1.9, COUNTER_TOP + 0.45, COUNTER_Z - 0.1), (1.2, 0.9, 1.0), yaw=-12)
    pebble_nuke(pebbles, amber_l, pebbles, (-3.6, COUNTER_TOP, COUNTER_Z), scale=0.9, yaw=10)
    pebble_nuke(pebbles, amber_r, pebbles, (3.4, COUNTER_TOP, COUNTER_Z + 0.1), scale=0.9, yaw=-20)

    # Rope ladder hanging from the rim at the back.
    for x in (-0.65, 0.65):
        bar(rope, (x, NEST_RIM_Y, 9.35), (x, 0.4, 9.35), 0.16)
    y = 1.2
    while y < NEST_RIM_Y - 0.6:
        box(twigs, (0, y, 9.35), (1.6, 0.18, 0.26))
        y += 1.25
    return m


# ------------------------------------------------------------------------------------------------
# D3_PteroCourier — routed flyer (R56)
# ------------------------------------------------------------------------------------------------

WING_Y = 2.6  # wing hinge height (both wings flap about the body centre line at this height)


def _wing(piece, side: int):
    """Flat gliding wing (membrane plate + leading-edge arm) from the body centre line outward."""
    # Outline (u = span outward from x 0.3, v = chord, + = forward / -Z).
    shape = [(0.3, 0.75), (2.6, 1.0), (5.3, 0.1), (3.3, -0.7), (1.5, -1.45), (0.3, -1.15)]
    outline = [(side * u, WING_Y, -v) for u, v in shape]
    prism(piece, outline, (0, 1, 0), 0.18)
    # Leading-edge arm centred on the membrane's mid-plane, so the wing's box stays centred on WING_Y.
    tube(piece, [(side * 0.3, WING_Y, -0.7), (side * 2.6, WING_Y, -0.95), (side * 5.3, WING_Y, -0.1)], 0.16, sides=5, radii=[0.2, 0.17, 0.08])


def build_ptero_courier():
    """
    Ptero Express courier (routed: VehicleRoutes flies the whole model, R25): a round coral ptero in
    a gliding pose with flat wings, a beak and crest, carrying a parcel in its feet. Pivot = parcel
    bottom (it perches on its parcel), front -Z. WingL / WingR are balanced about the centre line.
    """
    m = Model("D3_PteroCourier", "parcel bottom centre (perches on its parcel); faces -Z", budget=1500)
    body = m.piece("Body", PTERO_CORAL, material="StudsSmall")
    belly = m.piece("Belly", BONE, material="StudsSmall")
    beak = m.piece("Beak", BEAK, material="StudsSmall")
    eye = m.piece("Eyes", EYE, material="Smooth")
    wing_l = m.piece("WingL", WING_CORAL, material="StudsSmall")
    wing_r = m.piece("WingR", WING_CORAL, material="StudsSmall")
    box_p = m.piece("Parcel", PARCEL, material="StudsSmall")
    tie = m.piece("ParcelTie", SCARF, material="StudsSmall")
    # Parcel held in the feet (route cargo).
    parcel(box_p, tie, (0, 0.6, 0.1), (1.5, 1.2, 1.3), bow=False)
    # Body, belly, tail.
    ellipsoid(body, (0, 2.45, 0.1), (0.95, 0.95, 1.55), rings=6, segments=10)
    ellipsoid(belly, (0, 2.08, -0.05), (0.72, 0.55, 1.2), rings=5, segments=8)
    tube(body, [(0, 2.5, 1.5), (0, 2.6, 2.6), (0, 2.75, 3.3)], 0.3, sides=5, radii=[0.34, 0.16, 0.06])
    prism(body, [(0, 2.75, 3.1), (0, 3.25, 3.6), (0, 2.75, 4.0), (0, 2.25, 3.6)], (1, 0, 0), 0.14)  # tail diamond
    # Head, beak, crest, eyes.
    ellipsoid(body, (0, 3.3, -1.55), (0.78, 0.72, 0.85), rings=6, segments=10)
    cylinder(beak, (0, 3.15, -2.25), (0, 2.98, -4.0), 0.38, segments=6, radius_b=0.05)
    prism(beak, [(0, 3.72, -1.25), (0, 4.3, 0.95), (0, 3.55, -0.3)], (1, 0, 0), 0.22)  # crest sweeps back
    for s in (-1, 1):
        pt, n = surface((0, 3.3, -1.55), (0.78, 0.72, 0.85), s * 34, 14)
        oriented_ellipsoid(eye, tuple(pt - n * 0.04), (0.17, 0.22, 0.08), normal=tuple(n), rings=4, segments=7)
    # Legs gripping the parcel top.
    for s in (-1, 1):
        cylinder(beak, (s * 0.45, 1.95, 0.1), (s * 0.5, 1.28, 0.05), 0.15, segments=5)
        block(beak, (s * 0.5, 1.28, -0.12), (0.4, 0.14, 0.7), bevel=0.0)
    # Wings, each balanced about the centre line (cube hidden inside the opposite wing).
    _wing(wing_l, -1)
    _wing(wing_r, 1)
    # The cube lands on the opposite wing's tip (x = -lo), inside the leading-edge arm's end cap.
    balance(wing_l, (0.0, WING_Y, 0.0), axes=(0,), free=(0.0, WING_Y, -0.1))
    balance(wing_r, (0.0, WING_Y, 0.0), axes=(0,), free=(0.0, WING_Y, -0.1))
    return m


# ------------------------------------------------------------------------------------------------
# D3_RopeBridge — lookout tree + rope bridge to the nest rim
# ------------------------------------------------------------------------------------------------

LOOKOUT_DECK = 20.0  # lookout platform top, local y
BRIDGE_X0 = 3.7  # bridge start (platform edge), local x
BRIDGE_X1 = 21.7  # bridge end (0.15 short of the nest rim at slot x -9.15 when placed at x -31)
BRIDGE_Y1 = 21.0  # deck height at the nest end
BRIDGE_SAG = 1.0


def _bridge_y(t: float) -> float:
    """Deck height along the bridge (t 0..1): straight line platform -> rim, minus a parabolic sag."""
    return LOOKOUT_DECK + (BRIDGE_Y1 - LOOKOUT_DECK) * t - 4 * BRIDGE_SAG * t * (1 - t)


def build_rope_bridge():
    """A lookout tree (trunk, plank platform, stick railing, rope rail, leaf canopy, ladder) and a
    sagging plank-and-rope bridge running toward +X to the Ptero Post nest rim."""
    m = Model("D3_RopeBridge", "lookout trunk base centre; bridge runs toward +X to the nest rim (x 21.7)", budget=2500)
    bark = m.piece("Bark", BARK)
    planks = m.piece("Planks", BARK_DARK, material="StudsSmall")
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    canopy = m.piece("Canopy", JUNGLE)
    canopy_top = m.piece("CanopyTop", LEAF_LIGHT)
    # Trunk.
    cylinder(bark, (0, 0, 0), (0, 1.2, 0), 2.6, segments=10, radius_b=1.8)
    cylinder(bark, (0, 1.1, 0), (0, 12.0, 0), 1.8, segments=10, radius_b=1.55)
    cylinder(bark, (0, 11.9, 0), (0, 25.5, 0), 1.55, segments=10, radius_b=1.15)
    # Platform (plank disc) + stick railing with a gap toward +X for the bridge, rope rail.
    disc(planks, (0, LOOKOUT_DECK - 0.6, 0), 3.7, 0.6, segments=12, bevel=0.12)
    posts = []
    for k in range(9):
        a = math.radians(40 + k * 35)  # 40 .. 320 deg: leaves the +X side open for the bridge
        x, z = 3.35 * math.cos(a), 3.35 * math.sin(a)
        posts.append((x, z))
        bar(bark, (x, LOOKOUT_DECK - 0.1, z), (x, LOOKOUT_DECK + 1.7, z), 0.26)
    for (x0, z0), (x1, z1) in zip(posts, posts[1:]):
        bar(rope, (x0, LOOKOUT_DECK + 1.45, z0), (x1, LOOKOUT_DECK + 1.45, z1), 0.14)
    # Ladder down the -X side (rails + rungs).
    for z in (-0.6, 0.6):
        bar(rope, (-1.95, 0.3, z), (-1.95, LOOKOUT_DECK - 0.6, z), 0.16)
    y = 1.0
    while y < LOOKOUT_DECK - 1.0:
        box(planks, (-1.95, y, 0), (0.26, 0.18, 1.5))
        y += 1.3
    # Canopy above the platform.
    for c, r in (((0, 27.2, 0), (4.6, 2.4, 4.6)), ((2.2, 25.6, 1.8), (3.0, 1.8, 3.0)), ((-2.4, 25.8, -1.2), (3.2, 1.8, 3.0))):
        ellipsoid(canopy, c, r, rings=5, segments=10)
    ellipsoid(canopy_top, (0.4, 29.0, 0.2), (2.8, 1.2, 2.8), rings=4, segments=8)
    # Bridge planks (tilted to the local slope) + side rope rails + hanger ropes + end posts.
    count = 15
    span = BRIDGE_X1 - BRIDGE_X0
    for i in range(count):
        t = (i + 0.5) / count
        x = BRIDGE_X0 + span * t
        y = _bridge_y(t)
        dt = 0.01
        slope = (_bridge_y(min(1.0, t + dt)) - _bridge_y(max(0.0, t - dt))) / (2 * dt * span)
        block(planks, (x, y - 0.1, 0), (span / count - 0.22, 0.18, 2.3), bevel=0.0, rot=rot_z(math.degrees(math.atan(slope))))
    for z in (-1.2, 1.2):
        rail = []
        for i in range(9):
            t = i / 8
            rail.append((BRIDGE_X0 + span * t, _bridge_y(t) + 1.4 - 0.35 * (4 * t * (1 - t)), z))
        tube(rope, rail, 0.09, sides=5)
        for i in range(1, count, 2):
            t = (i + 0.5) / count
            x = BRIDGE_X0 + span * t
            top_y = _bridge_y(t) + 1.4 - 0.35 * (4 * t * (1 - t))
            bar(rope, (x, _bridge_y(t) - 0.05, z), (x, top_y, z), 0.08)
        bar(bark, (BRIDGE_X0 + 0.1, LOOKOUT_DECK - 0.1, z), (BRIDGE_X0 + 0.1, LOOKOUT_DECK + 1.7, z), 0.28)
        bar(bark, (BRIDGE_X1 - 0.1, BRIDGE_Y1 - 0.6, z), (BRIDGE_X1 - 0.1, BRIDGE_Y1 + 1.7, z), 0.28)
    return m


# ------------------------------------------------------------------------------------------------
# Small builds: baskets, wind sock, flock, map, landing pad
# ------------------------------------------------------------------------------------------------


def build_parcel_baskets():
    """Two wicker baskets heaped with parcels and a little parcel stack (placed twice)."""
    m = Model("D3_ParcelBaskets", "ground centre; faces -Z", budget=1500)
    wicker = m.piece("Wicker", THATCH, material="StudsSmall")
    bands = m.piece("Bands", BARK_DARK, material="StudsSmall")
    parcels = m.piece("Parcels", PARCEL, material="StudsSmall")
    ties = m.piece("Ties", SCARF, material="StudsSmall")
    basket(wicker, bands, (-0.9, 0, 0.3), 1.5, 1.6)
    basket(wicker, bands, (1.5, 0, -0.7), 1.1, 1.2)
    parcel(parcels, ties, (-1.2, 1.55, 0.2), (1.2, 0.9, 1.0), yaw=20)
    parcel(parcels, ties, (-0.4, 1.75, 0.6), (0.9, 0.8, 0.9), yaw=-25)
    parcel(parcels, ties, (1.5, 1.2, -0.7), (0.9, 0.7, 0.8), yaw=10)
    parcel(parcels, ties, (1.3, 0.5, 1.6), (1.2, 1.0, 1.1), yaw=-8)
    parcel(parcels, ties, (1.35, 1.48, 1.55), (0.9, 0.8, 0.85), yaw=14)
    return m


def build_wind_sock():
    """Bamboo pole on a boulder footing with a striped sock (Sock / SockStripes) and a mirrored
    ptero-head counter-vane, so both pieces' boxes are centred on the pole (swing about Y)."""
    m = Model("D3_WindSock", "pole base centre on the floor; sock streams toward +X", budget=900)
    rocks = m.piece("Rocks", STONE)
    pole = m.piece("Pole", BAMBOO, material="StudsSmall")
    nodes = m.piece("PoleNodes", BAMBOO_DARK, material="StudsSmall")
    sock = m.piece("Sock", SCARF, material="StudsSmall")
    stripes = m.piece("SockStripes", BONE, material="StudsSmall")
    for k in range(3):
        a = 2 * math.pi * k / 3 + 0.4
        boulder(rocks, (0.9 * math.cos(a), 0.3, 0.9 * math.sin(a)), (0.9, 0.6, 0.8), seed=k + 3, floor=0.0)
    cylinder(pole, (0, 0, 0), (0, 9.0, 0), 0.26, segments=8)
    for y in (2.5, 5.0, 7.5):
        cylinder(nodes, (0, y - 0.1, 0), (0, y + 0.1, 0), 0.32, segments=8)
    y0 = 9.15
    # Swivel collar (symmetric about the pole) + sock frustum + mouth hoop.
    cylinder(sock, (0, y0 - 0.35, 0), (0, y0 + 0.35, 0), 0.42, segments=8)
    cylinder(sock, (0.42, y0, 0), (5.4, y0 - 0.55, 0), 0.9, segments=10, radius_b=0.42)
    # Counter-vane: ptero head silhouette pointing -X, x extents mirror the sock (-5.4 .. -0.42).
    vane = [(-0.42, y0 + 0.5, 0), (-2.6, y0 + 0.75, 0), (-4.0, y0 + 1.15, 0), (-3.4, y0 + 0.25, 0), (-5.4, y0 - 0.2, 0), (-2.4, y0 - 0.55, 0), (-0.42, y0 - 0.45, 0)]
    prism(sock, vane, (0, 0, 1), 0.2)
    # Stripes: two bands on the sock (0.05 proud) and mirrored eye patches on the vane.
    for xa, xb in ((1.5, 2.3), (3.5, 4.3)):
        ya = y0 - 0.55 * (xa - 0.42) / 4.98
        yb = y0 - 0.55 * (xb - 0.42) / 4.98
        ra = 0.9 + (0.42 - 0.9) * (xa - 0.42) / 4.98 + 0.05
        rb = 0.9 + (0.42 - 0.9) * (xb - 0.42) / 4.98 + 0.05
        cylinder(stripes, (xa, ya, 0), (xb, yb, 0), ra, segments=10, radius_b=rb)
    for face in (-0.12, 0.12):
        # Eye patches on both vane faces (0.06 thick, 0.05 proud of the 0.2 vane: R18).
        prism(stripes, [(-4.3, y0 + 0.2, face), (-1.5, y0 + 0.3, face), (-1.5, y0 - 0.1, face), (-4.3, y0 - 0.05, face)], (0, 0, 1), 0.06)
    return m


def _perched_ptero(body, belly, beak, eye, base, yaw: float, scale: float = 1.0):
    """A small perched ptero (wings folded along the body) gripping a perch at `base`, facing yaw."""
    xf = Xf(base, yaw=yaw)
    s = scale
    r = xf.rot
    ellipsoid(body, xf.p(0, 0.95 * s, 0.1 * s), (0.62 * s, 0.85 * s, 0.72 * s), rings=6, segments=8)
    oriented_ellipsoid(belly, xf.p(0, 0.85 * s, -0.32 * s), (0.45 * s, 0.6 * s, 0.4 * s), normal=tuple(r @ Vector((0, 0, -1))), rings=4, segments=8)
    ellipsoid(body, xf.p(0, 2.05 * s, -0.2 * s), (0.56 * s, 0.52 * s, 0.6 * s), rings=5, segments=8)
    cylinder(beak, xf.p(0, 1.95 * s, -0.7 * s), xf.p(0, 1.82 * s, -1.95 * s), 0.26 * s, segments=6, radius_b=0.04 * s)
    prism(beak, [xf.p(0, 2.4 * s, -0.25 * s), xf.p(0, 2.8 * s, 1.05 * s), xf.p(0, 2.3 * s, 0.35 * s)], tuple(r @ Vector((1, 0, 0))), 0.18 * s)
    for side in (-1, 1):
        # Folded wing: a flat plate along the body side.
        wing = [xf.p(side * 0.66 * s, 1.55 * s, -0.4 * s), xf.p(side * 0.7 * s, 1.2 * s, 0.9 * s), xf.p(side * 0.62 * s, 0.25 * s, 1.1 * s), xf.p(side * 0.6 * s, 0.6 * s, -0.1 * s)]
        prism(body, wing, tuple(r @ Vector((1, 0, 0))), 0.14 * s)
        pt, n = surface((0, 0, 0), (0.56 * s, 0.52 * s, 0.6 * s), side * 34, 16)
        c = Vector(xf.p(pt.x, 2.05 * s + pt.y, -0.2 * s + pt.z)) - (r @ n) * 0.03
        oriented_ellipsoid(eye, tuple(c), (0.13 * s, 0.17 * s, 0.06 * s), normal=tuple(r @ n), rings=4, segments=6)
        block(beak, xf.p(side * 0.28 * s, 0.08 * s, -0.12 * s), (0.3 * s, 0.16 * s, 0.6 * s), bevel=0.0, rot=r)


def build_ptero_flock():
    """Three perched pteros (teal, coral, lilac) on a driftwood perch with forked posts."""
    m = Model("D3_PteroFlock", "ground centre; perch along local X, birds face -Z", budget=2500)
    perch = m.piece("Perch", BARK)
    posts = m.piece("Posts", BARK_DARK)
    teal = m.piece("BodyTeal", PTERO_TEAL, material="StudsSmall")
    coral = m.piece("BodyCoral", PTERO_CORAL, material="StudsSmall")
    lilac = m.piece("BodyLilac", PTERO_LILAC, material="StudsSmall")
    belly = m.piece("Bellies", BONE, material="StudsSmall")
    beak = m.piece("Beaks", BEAK, material="StudsSmall")
    eye = m.piece("Eyes", EYE, material="Smooth")
    perch_y = 3.6
    cylinder(perch, (-5.2, perch_y - 0.2, 0), (5.2, perch_y + 0.2, 0), 0.36, segments=8)
    for x in (-3.9, 3.9):
        bar(posts, (x, 0, 0), (x, perch_y - 0.1, 0), 0.5)
        bar(posts, (x, perch_y - 1.2, 0), (x - 0.6, perch_y + 0.5, 0), 0.26)
        bar(posts, (x, perch_y - 1.2, 0), (x + 0.6, perch_y + 0.5, 0), 0.26)
        boulder(posts, (x, 0.2, 0), (0.7, 0.4, 0.7), seed=int(x) + 9, floor=0.0)
    for body, x, yaw, scale in ((teal, -2.6, 18, 1.0), (coral, 0.2, -6, 1.15), (lilac, 2.9, -24, 0.95)):
        top = perch_y + 0.2 * (x / 5.2) + 0.36
        _perched_ptero(body, belly, beak, eye, (x, top, 0), yaw, scale)
    return m


def build_treasure_map():
    """Parchment treasure map on a log-framed board: dotted route, a big red X, palm icons, a
    little volcano, waves. Ink is raised blocks (each layer proud of the last: R18)."""
    m = Model("D3_TreasureMap", "ground centre; map faces -Z", budget=1500)
    logp = m.piece("Logs", BARK)
    frame = m.piece("Frame", BARK_DARK)
    paper = m.piece("Paper", BONE, material="Smooth")
    red = m.piece("InkRed", INK_RED, material="Smooth")
    blue = m.piece("InkBlue", INK_BLUE, material="Smooth")
    green = m.piece("InkGreen", INK_GREEN, material="Smooth")
    brown = m.piece("InkBrown", INK_BROWN, material="Smooth")
    for x in (-3.6, 3.6):
        cylinder(logp, (x, 0, 0.2), (x, 7.0, 0.2), 0.45, segments=8)
    cy, w, h, depth = 4.4, 7.6, 5.0, 0.5
    sign_frame(frame, paper, (0, cy, 0), (w, h), border=0.4, depth=depth)
    face = -depth * 0.35  # paper front face z
    ink = 0.06

    def mark(piece, x, y, sx, sy, layer: int = 0, angle: float = 0.0):
        """Ink block on the paper face (layer > 0 stacks 0.03 further out so crossings never share a plane)."""
        t = ink + 0.03 * layer
        block(piece, (x, cy + y, face - t / 2), (sx, sy, t), bevel=0.0, rot=rot_z(angle))

    # Dotted route from the bottom-left island to the X.
    for k, (x, y) in enumerate(((-2.6, -1.4), (-2.0, -0.9), (-1.3, -0.7), (-0.6, -0.9), (0.1, -0.6), (0.6, -0.15), (0.9, 0.3))):
        mark(red, x, y, 0.28, 0.28)
    mark(red, 1.75, 0.95, 1.2, 0.3, 0, 45)
    mark(red, 1.75, 0.95, 1.2, 0.3, 1, -45)
    # Waves (blue) along the bottom + a lake.
    for k in range(4):
        mark(blue, -2.7 + 1.6 * k, -1.85, 0.9, 0.18, 0, 18 if k % 2 == 0 else -18)
    mark(blue, -2.4, 1.2, 1.3, 0.7)
    # Palm icons (green): trunk + three leaf strokes.
    for px, py in ((-0.7, 0.6), (2.6, -1.0)):
        mark(brown, px, py - 0.3, 0.14, 0.6)
        for layer, a in enumerate((-35, 0, 35)):
            # each stroke on its own layer: the three fan out of one point and would share a plane
            mark(green, px + 0.25 * math.sin(math.radians(a)), py + 0.1, 0.6, 0.14, 1 + layer, a)
    # Volcano (brown triangle) with a lava cap stroke.
    prism(brown, [(1.1, cy + 1.45, face - ink / 2), (2.9, cy + 1.45, face - ink / 2), (2.1, cy + 2.05, face - ink / 2)], (0, 0, 1), ink)
    mark(red, 2.1, 1.98, 0.42, 0.12, 1)
    # Rolled spare map on top of the frame.
    cylinder(paper, (-2.8, cy + h / 2 + 0.38, -0.1), (2.8, cy + h / 2 + 0.38, -0.1), 0.36, segments=8)
    for x in (-1.9, 1.9):
        cylinder(red, (x - 0.1, cy + h / 2 + 0.38, -0.1), (x + 0.1, cy + h / 2 + 0.38, -0.1), 0.41, segments=8)
    return m


def build_landing_pad():
    """Woven landing deck on a stone ring: green target ring, a big three-toed ptero footprint,
    four bamboo lantern posts (Smooth soft glow, R19) and a front step."""
    m = Model("D3_LandingPad", "ground centre; front step toward -Z", budget=2000)
    stone = m.piece("Stone", STONE)
    deck = m.piece("Deck", THATCH)
    paint = m.piece("Paint", INK_GREEN, material="StudsSmall")
    mark = m.piece("Print", BONE, material="StudsSmall")
    posts = m.piece("Posts", BAMBOO, material="StudsSmall")
    caps = m.piece("Caps", BARK_DARK, material="StudsSmall")
    glow = m.piece("Lanterns", AMBER_SOFT, material="Smooth")
    disc(stone, (0, 0, 0), 7.4, 0.9, segments=16, bevel=0.2)
    disc(deck, (0, 0.9, 0), 6.8, 0.3, segments=16, bevel=0.08)
    top = 1.2
    ring_tube(paint, (0, top + 0.06, 0), 4.6, 0.8, 0.12, segments=16)
    # Footprint: heel pad + three toes (flat, 0.12 tall on the deck).
    block(mark, (0, top + 0.06, 0.7), (1.8, 0.12, 1.6), bevel=0.04)
    for a in (-32, 0, 32):
        # side toes 0.04 taller than the middle one: where they meet, their tops never share a plane
        h = 0.12 if a == 0 else 0.16
        d = Vector((math.sin(math.radians(a)), 0.0, -math.cos(math.radians(a))))
        c = Vector((0, top + h / 2, 0.0)) + d * 1.5
        block(mark, tuple(c), (0.6, h, 1.6), bevel=0.04, rot=frame_from(Vector((-d.z, 0.0, d.x)), Vector((0, 1, 0))))
    for k in range(4):
        a = math.radians(45 + 90 * k)
        x, z = 7.0 * math.sin(a), -7.0 * math.cos(a)
        cylinder(posts, (x, 0.9, z), (x, 3.3, z), 0.2, segments=6)
        ellipsoid(glow, (x, 3.75, z), (0.42, 0.5, 0.42), rings=4, segments=6)
        cylinder(caps, (x, 4.15, z), (x, 4.5, z), 0.5, segments=6, radius_b=0.1)
    block(stone, (0, 0.3, -7.75), (3.6, 0.6, 1.3), bevel=0.12)
    return m


# ------------------------------------------------------------------------------------------------
# D3_CaptainPtera — manager NPC (R30)
# ------------------------------------------------------------------------------------------------


def build_captain_ptera():
    """
    Captain Ptera (Manager NPC, owner R30): a teal ptero postmaster on W6's shared dino body, with a
    long beak and a swept-back crest, a navy captain's cap with a gold envelope badge, a red
    neckerchief, a mail satchel on a strap and a parcel held in front. Wing membranes hang from the
    arms. Figure ONLY; split into the R30 rig pieces (models/_npc_rig.py).
    """
    from models._npc_rig import rig_split

    m = Model("D3_CaptainPtera", "feet centre; faces -Z", budget=3000)
    skin = m.piece("Skin", PTERO_TEAL, material="StudsSmall")
    tail = m.piece("Tail", PTERO_TEAL, material="StudsSmall")
    belly = m.piece("Belly", BONE, material="StudsSmall")
    face = m.piece("Face", EYE, material="Smooth")
    shine = m.piece("Shine", WHITE, material="Smooth")
    beak = m.piece("Beak", BEAK, material="StudsSmall")
    hat = m.piece("Hat", NAVY, material="StudsSmall")
    scarf = m.piece("Scarf", SCARF, material="StudsSmall")
    satchel = m.piece("Satchel", BARK, material="StudsSmall")
    mem_l = m.piece("MembraneL", WING_TEAL, material="StudsSmall")
    mem_r = m.piece("MembraneR", WING_TEAL, material="StudsSmall")
    held = m.piece("Parcel", PARCEL, material="StudsSmall")
    # Right arm reaches forward to hold the parcel against the chest; left arm relaxed.
    a = dino_biped(
        {"skin": skin, "belly": belly, "face": face, "shine": shine, "tail": tail},
        snout=0.5,
        arm_pose={"right": (-18.0, 78.0)},
    )
    hc = Vector(a["head"])
    tip = Vector(a["snout_tip"])
    # Long beak out of the short snout + a crest sweeping back from under the cap.
    cylinder(beak, (0, tip.y + 0.12, tip.z + 0.45), (0, tip.y - 0.2, tip.z - 1.7), 0.44, segments=7, radius_b=0.05)
    prism(skin, [(0, hc.y + 0.25, hc.z + 0.55), (0, hc.y + 0.8, hc.z + 2.3), (0, hc.y - 0.1, hc.z + 1.1)], (1, 0, 0), 0.3)
    # Captain's cap: crown + peak + gold envelope badge (0.08 proud of the crown front).
    top = a["head_top"]
    revolve(hat, [(0.0, 0.62), (0.78, 0.6), (0.92, 0.3), (0.86, 0.0), (0.0, 0.0)], center=(0, top - 0.24, hc.z + 0.05), segments=12)
    block(hat, (0, top - 0.22, hc.z - 0.9), (1.3, 0.12, 0.7), bevel=0.04, rot=rot_x(-12))
    block(beak, (0, top + 0.09, hc.z - 0.9), (0.5, 0.34, 0.08), bevel=0.0)
    # Neckerchief: a ring round the neck + knot + two tails on the chest.
    neck = a["neck"]
    chest = Vector(a["chest"])
    ring_tube(scarf, (0, neck + 0.05, -0.05), 0.95, 0.26, 0.32, segments=10)
    block(scarf, (0, neck - 0.25, chest.z + 0.08), (0.44, 0.42, 0.22), bevel=0.06)
    for s in (-1, 1):
        block(scarf, (s * 0.2, neck - 0.68, chest.z + 0.05), (0.26, 0.62, 0.12), bevel=0.0, rot=rot_z(s * 18))
    # Mail satchel on the left hip + strap over the right shoulder.
    bc = Vector(a["body_c"])
    bw, bh, bd = a["body"]
    block(satchel, (-(bw + 0.05), bc.y - 0.55, bc.z + 0.15), (0.5, 1.0, 1.2), bevel=0.12)
    strap = []
    for t in (0.0, 0.33, 0.66, 1.0):
        x = 0.95 - 2.1 * t
        y = bc.y + 0.95 - 1.35 * t
        # On the body front: z from the body ellipsoid at (x, y), 0.14 proud (strap radius 0.12).
        q = max(0.0, 1 - (x / bw) ** 2 - ((y - bc.y) / bh) ** 2)
        z = bc.z - bd * math.sqrt(q) - 0.14
        strap.append((x, y, z))
    tube(satchel, strap, 0.12, sides=4)
    # Wing membranes from each arm down to the body side (assigned to the arm rig groups).
    sy, sx, sz = a["shoulder_y"], a["shoulder_x"], a["shoulder_z"]
    for s, piece, side in ((-1, mem_l, "left"), (1, mem_r, "right")):
        hand = Vector(a["hands"][side])
        prism(piece, [(s * (sx + 0.05), sy - 0.05, sz + 0.25), (hand.x + s * 0.05, hand.y + 0.1, hand.z + 0.25), (s * (bw + 0.02), bc.y - 0.7, bc.z + 0.3)], (1, 0, 0), 0.1)
    # Parcel held in the right hand, in front of the chest.
    hand_r = Vector(a["hands"]["right"])
    parcel(held, scarf, (hand_r.x - 0.5, hand_r.y, hand_r.z - 0.45), (1.3, 0.95, 0.9), yaw=0, bow=True)
    rig_split(
        m,
        dino_bones(a),
        assign={"Tail": "Torso", "MembraneL": "ArmL", "MembraneR": "ArmR", "Parcel": "ArmR"},
        frame=((0.0, 0.0, 0.0), 0.0),
    )
    return m


BUILDERS = {
    "D3_Floor": build_floor,
    "D3_EntryArch": build_entry_arch,
    "D3_Jungle": build_jungle,
    "D3_NestTower": build_nest_tower,
    "D3_PteroCourier": build_ptero_courier,
    "D3_RopeBridge": build_rope_bridge,
    "D3_ParcelBaskets": build_parcel_baskets,
    "D3_WindSock": build_wind_sock,
    "D3_PteroFlock": build_ptero_flock,
    "D3_TreasureMap": build_treasure_map,
    "D3_LandingPad": build_landing_pad,
    "D3_CaptainPtera": build_captain_ptera,
}
