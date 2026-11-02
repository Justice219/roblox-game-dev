"""
dino_area04.py — Dino Valley area D4 "Geyser Springs" (World 2 spec §6.2 / §16, owner R57): a warm
sandy-stone geyser field where a bamboo pump steams pebble nukes at a bubbling vent, bamboo pipes
feed a big wooden water wheel and a pair of hot-spring pools (a baby dino is having a soak), steam
whistles toot, valve wheels hiss and a terraced Mega Geyser shoots a tall water column at the back.
Every pad purchase is its own model set so each one builds in separately; placement lives in
src/shared/Config/Worlds/Dino/Layouts/Area04.luau.

Shared helpers come from dino_area03.py (palette, foliage, parcels, pebble nukes, balance) and the
manager body from W6's dino_area01.py (`dino_biped` / `dino_bones`, same body in every Dino area).

Every model has its OWN pivot (ground centre unless stated, front = -Z). The layout places it with
a slot-local CFrame (identity faces the road); floor-standing models sit at y = 0.4 (floor top).

Models (key: pivot / notes)                                       build key
    D4_Floor          slab centre at ground; top y = 0.4              base
    D4_EntryArch      ground centre of the walkway opening; boulder    base
                      pillars, bamboo header, double-sided "GEYSER /
                      SPRINGS" letters (R17), a little geyser topper
    D4_Rocks          slot origin on the floor top; mossy back rocks,  base
                      bamboo clumps, side ferns (L / R pieces, R31)
    D4_GeyserVent     PRODUCER "Geyser Pump": stone vent mound with a  D4_GeyserVent
                      bobbing water Column, bamboo pump spout over a
                      log bench of pebble nukes; pivot = mound centre
    D4_BambooPipes    two pipe runs on trestles, pivot = the vent      D4_BambooPipes
                      centre: +X to the wheel riser, -X to the springs
    D4_WaterWheel     wheel (Wheel / WheelTrim spin about local X),    D4_WaterWheel
                      A-frames, stone trough, riser + aqueduct; axle
                      along local X (placed yaw 90 so it faces the road)
    D4_SteamWhistles  bamboo manifold with four whistles + puffs       D4_SteamWhistles
    D4_HotSprings     raised upper pool + lower pool, Ripple rings,    D4_HotSprings
                      a bathing baby dino, inlet riser at local (10.15, y, -1)
    D4_PressureValves plinth, manifold, three valve wheels, gauges     D4_PressureValves
    D4_MegaGeyser     HERO: terraced mineral mound, tall Column,       D4_MegaGeyser
                      rivulets, rope fence arc, "WHOOSH!" sign
    D4_ParaPete       Manager NPC figure ONLY (R30 rig groups)         D4_ParaPete
    D4_StoneSteps     rock lookout with steps, log bench, railing      D4_StoneSteps

Animation contract (piece names; rows are W10's WorldFxConfig work):
    Wheel / WheelTrim  D4_WaterWheel: spin about local X (the existing `Wheel` row). Both pieces are
                       rotationally symmetric about the axle (12 paddles, 8 spokes, round rims, hub),
                       so their box centres sit on the axle (0, AXLE_Y, 0).
    Column             D4_GeyserVent + D4_MegaGeyser water columns: bob along Y. Each column starts
                       deep inside its mound, so a bob never shows a gap. NOTE for W10: area06 /
                       area09 have STATIC pieces named "Column", so animate these through
                       WorldFxConfig.Assemblies keyed by D4_GeyserVent / D4_MegaGeyser, not a global
                       `Column` row.
    Ripple             D4_HotSprings ripple rings: the existing `Ripple` row (bob 0.06); each ring
                       floats 0.07 above its water so the bob never dips into it.
    Steam              D4_GeyserVent, D4_SteamWhistles, D4_HotSprings, D4_MegaGeyser: one small steam
                       anchor each (existing `Steam` particle row).
    Static on purpose: "Puffs" (sculpted steam clouds), "Valve*" wheels, "Amber*" pebble cores.

Glow budget (owner R19): Neon only on the pebble-nuke cores (one small piece per nuke). Water is
Smooth, never Neon.

Budgets: floor <= 2,500, arch <= 4,500, backdrop <= 4,500, producer <= 4,500, hero <= 6,000,
props <= 2,500, manager <= 3,000. A fully built D4 stays <= 28k triangles (spec §15).
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import WHITE, Model
from snkit.kit import block, disc, sign_frame
from snkit.shapes import bar, box, cylinder, ellipsoid, frame_from, loft, prism, revolve, ring_tube, rot_y, rot_z

from models._critter_kit import oriented_ellipsoid, surface, tube
from models.area01 import block_text
from models.area04 import _hash
from models.dino_area01 import bone, dino_biped, dino_bones
from models.dino_area03 import (
    AMBER,
    BAMBOO,
    BAMBOO_DARK,
    BARK,
    BARK_DARK,
    BEAK,
    BONE,
    EYE,
    FERN_DARK,
    FLOOR_TOP,
    INK_RED,
    MOSS,
    PEBBLE,
    ROPE,
    SAND,
    SCARF,
    SLOT_D,
    SLOT_W,
    STONE,
    STONE_DARK,
    WATER,
    WATER_LIGHT,
    _chute_section,
    arch_sign,
    boulder,
    fern,
    leaf,
    pebble_nuke,
)

# Area-local palette (warm geothermal tones; shared Dino palette in dino_area03.py).
SINTER = (255, 196, 96)  # amber mineral terraces (candy, not hazard)
SINTER_TEAL = (110, 204, 192)  # teal mineral rim round the crater
STEAM_WHITE = (240, 246, 250)  # sculpted steam puffs (Smooth)
WOOD = (204, 146, 88)  # water-wheel boards
LETTER_BLUE = (40, 110, 190)  # Smooth block letters on bone boards
PARA_LIME = (150, 206, 84)  # Para Pete's skin
PARA_CREST = (255, 136, 64)  # his crest
BILL = (255, 204, 140)  # his duck bill
OVERALLS = (72, 120, 210)
LENS = (176, 228, 248)
TOWEL = (255, 150, 186)
BABY = (170, 222, 110)
VALVE_TEAL = (76, 190, 200)

AXLE_Y = 7.2  # water-wheel axle height (local)
WHEEL_R = 6.0  # wheel outer radius


# ------------------------------------------------------------------------------------------------
# Small shared bits
# ------------------------------------------------------------------------------------------------


def bamboo_run(stalk, nodes, a, b, radius: float, node_step: float = 2.6, segments: int = 8):
    """
    Bamboo pole / pipe from a to b with darker node rings every `node_step` studs (rings 0.08
    proud of the pole so they never share its surface: R18). Ends get a node ring too.

    Example: bamboo_run(pipe, pipe_nodes, (5.2, 1.6, 0), (25.4, 1.6, 0), 0.42)
    """
    va, vb = Vector(a), Vector(b)
    d = vb - va
    length = d.length
    if length < 1e-4:
        return
    u = d / length
    cylinder(stalk, a, b, radius, segments=segments)
    count = max(1, int(length / node_step))
    for k in range(count + 1):
        t = k * length / count
        # End rings overhang the pole end by 0.05, so their caps never share the pole's end-cap
        # plane (R18); inner rings straddle their node.
        lo = -0.05 if k == 0 else t - 0.12
        hi = length + 0.05 if k == count else t + 0.12
        if k == 0:
            hi = 0.19
        elif k == count:
            lo = length - 0.19
        cylinder(nodes, tuple(va + u * lo), tuple(va + u * hi), radius + 0.08, segments=segments)


def puff(piece, center, scale: float = 1.0, seed: int = 0):
    """Sculpted cartoon steam cloud: three overlapping squashed balls (static, Smooth white)."""
    cx, cy, cz = center
    for k in range(3):
        a = 2.1 * k + seed
        r = scale * (0.55 + 0.2 * _hash(seed, k))
        ellipsoid(piece, (cx + 0.45 * scale * math.cos(a), cy + 0.25 * scale * k, cz + 0.45 * scale * math.sin(a)), (r, r * 0.8, r), rings=4, segments=7)


def water_jet(jet, foam, base_y: float, top_y: float, r0: float, r1: float, seed: int = 0, segments: int = 8):
    """
    Cartoon geyser jet: a stack of overlapping, slightly wobbling water blobs from base_y (radius
    r0) up to top_y (radius r1), a domed splash crown, a ring of droplets falling outward and white
    foam puffs round the crown. `jet` should be named "Column" and `foam` "ColumnFoam" (same leading
    word -> one WorldFx motion group, so foam and water bob together: R25).

    Example: water_jet(column, foam, 1.2, 11.4, 1.1, 0.75)
    """
    height = top_y - base_y
    count = max(3, round(height / (1.25 * (r0 + r1))))
    step = height / count
    for k in range(count + 1):
        t = k / count
        r = r0 + (r1 - r0) * t
        y = base_y + step * k
        wobble = 0.12 * r
        ox = wobble * math.sin(2.3 * k + seed)
        oz = wobble * math.cos(1.7 * k + seed)
        ellipsoid(jet, (ox, y, oz), (r, step * 0.78, r), rings=4, segments=segments)
    crown_y = top_y + step * 0.4
    ellipsoid(jet, (0, crown_y, 0), (r1 * 1.9, r1 * 0.85, r1 * 1.9), rings=4, segments=segments + 2)
    drops = 8
    for k in range(drops):
        a = 2 * math.pi * (k + 0.5 * _hash(seed, k)) / drops
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        for j, (rad, dy, size) in enumerate(((2.25, 0.1, 0.34), (2.9, -0.9, 0.26))):
            c = d * (r1 * rad) + Vector((0, crown_y + dy * r1, 0))
            ellipsoid(jet, tuple(c), (size * r1 * 1.4, size * r1 * 1.8, size * r1 * 1.4), rings=3, segments=6)
    for k in range(3):
        a = 2 * math.pi * k / 3 + seed
        puff(foam, (r1 * 1.3 * math.cos(a), crown_y + r1 * 0.35, r1 * 1.3 * math.sin(a)), scale=r1 * 0.75, seed=seed + k)


def stone_mound(piece, profile, center=(0, 0, 0), segments: int = 12):
    """Revolved stone mound (profile [(radius, y)] from the ground ring up to the crater floor)."""
    revolve(piece, profile, center=center, segments=segments)


def _mound_radius(profile, y: float) -> float:
    """Outer radius of a revolve profile at height y (linear between profile points; ground-up)."""
    for (r0, y0), (r1, y1) in zip(profile, profile[1:]):
        if y0 <= y <= y1 and y1 > y0:
            return r0 + (r1 - r0) * (y - y0) / (y1 - y0)
    return profile[0][0]


# ------------------------------------------------------------------------------------------------
# Base: floor, arch, rocks
# ------------------------------------------------------------------------------------------------


def build_floor():
    """Warm sandy-stone slab for the whole slot, a flagstone walkway to the pump bench, side paths
    to the wheel and the springs, moss patches and warm puddles (no two flat tops overlap: R18)."""
    m = Model("D4_Floor", "slab centre at ground (place at slot (0, 0, 35)); top y = 0.4", budget=2500)
    ground = m.piece("Ground", SAND)
    moss = m.piece("Moss", MOSS)
    flag = m.piece("Flagstones", STONE)
    puddle = m.piece("Puddles", WATER, material="Smooth")
    block(ground, (0, FLOOR_TOP / 2, 0), (SLOT_W, FLOOR_TOP, SLOT_D - 0.4), bevel=0.15)
    for i, (x, z, sx, sz) in enumerate(
        ((-34, -24, 11, 7), (30, -26, 9, 7), (-44, 0, 8, 9), (42, 4, 8, 8), (-18, 18, 9, 6), (22, 20, 8, 6), (-44, 22, 7, 6), (44, 28, 6, 5))
    ):
        block(moss, (x, FLOOR_TOP + 0.04, z), (sx, 0.12, sz), bevel=0.04, rot=rot_y(24 * (_hash(i, 12) - 0.5)))
    # Warm puddles (0.02 higher than the moss tops, never overlapping a patch or a flagstone).
    for i, (x, z, rx, rz) in enumerate(((-24, -12, 2.4, 1.6), (26, -8, 2.0, 1.4), (-12, 6, 1.6, 1.2))):
        ellipsoid(puddle, (x, FLOOR_TOP + 0.02, z), (rx, 0.1, rz), rings=3, segments=10)
    # Flagstone walkway: road edge (z -35) to the pump bench front (slot z 38.2 -> local 3.2).
    z = -34.6
    k = 0
    while z < 2.8:
        length = min(2.6 + 1.1 * _hash(k, 14), 3.2 - z)
        if length < 0.8:
            break
        off = 0.4 * (_hash(k, 15) - 0.5)
        for s in (-1, 1):
            block(flag, (s * 2.6 + off, FLOOR_TOP + 0.08, z + length / 2), (4.6, 0.2, length - 0.4), bevel=0.08)
        z += length
        k += 1
    # Side paths at slot z ~31 (local -4): +X toward the valves / wheel, -X toward the springs.
    for direction, x_end in ((1, 26.0), (-1, -24.0)):
        x = 6.2
        k = 0
        while x < abs(x_end):
            length = 2.6 + 0.8 * _hash(k + 20 * direction, 16)
            cx = direction * (x + length / 2)
            block(flag, (cx, FLOOR_TOP + 0.08, -4.0 + 0.5 * (_hash(k, 17) - 0.5)), (length - 0.4, 0.2, 3.0), bevel=0.08)
            x += length
            k += 1
    return m


def build_entry_arch():
    """Stacked mossy boulder pillars, a double bamboo header with node rings, the "GEYSER /
    SPRINGS" board (double-sided, R17) topped by a mini geyser, steam puffs and ferns."""
    m = Model("D4_EntryArch", "ground centre of the walkway opening; double-sided sign, front -Z (road)", budget=4500)
    rock = m.piece("Rock", STONE)
    moss = m.piece("Moss", MOSS)
    pole = m.piece("Bamboo", BAMBOO)
    nodes = m.piece("BambooNodes", BAMBOO_DARK, material="StudsSmall")
    frame = m.piece("Frame", BARK_DARK)
    board = m.piece("Board", BONE, material="Smooth")
    letters = m.piece("Letters", LETTER_BLUE, material="Smooth")
    puffs = m.piece("Puffs", STEAM_WHITE, material="Smooth")
    water = m.piece("Spout", WATER_LIGHT, material="Smooth")
    ferns = m.piece("Ferns", FERN_DARK)
    for s in (-1, 1):
        x = s * 9.6
        boulder(rock, (x, 2.0, 0), (2.6, 2.3, 2.4), seed=1 + s, floor=0.0)
        boulder(rock, (x + s * 0.2, 5.9, 0.1), (2.2, 2.0, 2.1), seed=4 + s)
        boulder(rock, (x - s * 0.1, 9.4, 0), (1.9, 1.8, 1.8), seed=7 + s)
        boulder(moss, (x, 11.15, 0), (1.5, 0.55, 1.45), seed=10 + s)
        boulder(rock, (x + s * 2.6, 0.9, -1.6), (1.3, 1.0, 1.1), seed=13 + s, floor=0.0)  # foot boulder
        puff(puffs, (x + s * 0.6, 14.9, 0.3), scale=0.9, seed=s + 3)  # steam above the pillar
        for k, (fx, fz) in enumerate(((s * 13.0, 1.2), (s * 7.6, -2.2))):
            fern(ferns, (fx, 0, fz), scale=1.0, seed=k + (30 if s > 0 else 40))
    # Bamboo header: two poles across the pillars (lashed into the boulders).
    bamboo_run(pole, nodes, (-12.2, 12.6, -0.3), (12.2, 12.6, -0.3), 0.6, node_step=3.0)
    bamboo_run(pole, nodes, (-11.4, 14.0, 0.4), (11.4, 14.0, 0.4), 0.5, node_step=3.0)
    for x in (-5.0, 5.0):
        bar(frame, (x, 14.3, 0), (x, 15.6, 0), 0.4)
    sign_y = 18.4
    arch_sign(frame, board, letters, ["GEYSER", "SPRINGS"], (0, sign_y, 0), (14.6, 6.2), 0.3)
    # Mini geyser on top: stone cone + spout of water + a puff.
    top = sign_y + 3.1
    revolve(rock, [(0.0, 0.0), (1.4, 0.0), (0.9, 0.9), (0.6, 1.1), (0.0, 1.1)], center=(0, top, 0), segments=10)
    cylinder(water, (0, top + 0.9, 0), (0, top + 2.8, 0), 0.32, segments=8, radius_b=0.22)
    puff(puffs, (0, top + 3.1, 0), scale=0.75, seed=9)
    return m


def build_rocks():
    """Mossy back-corner rock outcrops, bamboo clumps and side ferns (slot space, pivot = slot
    origin on the floor top). The back centre (|x| < 12) stays clear for the Mega Geyser; items
    near the road live in FernsL / FernsR so no piece box covers the billboard spot (R31)."""
    m = Model("D4_Rocks", "slot origin on the floor top (place at slot (0, 0.4, 0)); slot-space coordinates", budget=4500)
    rock = m.piece("Rock", STONE)
    dark = m.piece("RockDark", STONE_DARK)
    moss = m.piece("Moss", MOSS)
    stalks = m.piece("Stalks", BAMBOO)
    nodes = m.piece("StalkNodes", BAMBOO_DARK, material="StudsSmall")
    leaves = m.piece("Leaves", FERN_DARK)
    ferns_l = m.piece("FernsL", FERN_DARK)
    ferns_r = m.piece("FernsR", FERN_DARK)
    # Outcrops: big rock + a smaller dark one leaning on it + a moss cap.
    for i, (x, z, rx, ry, rz) in enumerate(((-40, 66, 5.0, 4.2, 3.6), (-22, 66.5, 4.2, 3.2, 3.2), (24, 66.5, 4.4, 3.4, 3.2), (42, 65.5, 5.2, 4.6, 3.8))):
        boulder(rock, (x, ry * 0.45, z), (rx, ry, rz), seed=i + 50, floor=0.0)
        boulder(dark, (x + (2.2 if x < 0 else -2.2), ry * 0.3, z - 2.0), (rx * 0.5, ry * 0.55, rz * 0.5), seed=i + 60, floor=0.0)
        boulder(moss, (x - 0.3, ry * 1.25, z + 0.2), (rx * 0.65, ry * 0.3, rz * 0.6), seed=i + 70)
    # Bamboo clumps (stalks with node rings and leaf tufts).
    for c, (cx, cz) in enumerate(((-47, 52), (-14, 61), (15, 61.5), (47, 54))):
        for k in range(4):
            a = 2 * math.pi * k / 4 + c
            x, z = cx + 0.9 * math.cos(a), cz + 0.9 * math.sin(a)
            h = 7.0 + 3.0 * _hash(c, k)
            lean = Vector((0.5 * math.cos(a), 0.0, 0.5 * math.sin(a)))
            base = (x, -0.1, z)
            top = (x + lean.x, h, z + lean.z)
            cylinder(stalks, base, top, 0.22, segments=6)
            for y in (h * 0.35, h * 0.7):
                t = y / h
                cylinder(nodes, (x + lean.x * t, y - 0.08, z + lean.z * t), (x + lean.x * t, y + 0.08, z + lean.z * t), 0.29, segments=6)
            for j in range(3):
                b = a + 2.1 * j
                d = (math.cos(b) * 0.8, -0.35, math.sin(b) * 0.8)
                leaf(leaves, top, d, 2.2, 0.7)
    for i, (zl, zr) in enumerate(((20.0, 34.0), (34.0, 41.0), (42.0, 48.0))):
        # (the -X side skips z 22..32: the stone-steps lookout stands there)
        fern(ferns_l, (48.5, 0, zl), scale=1.0, seed=i + 80)
        fern(ferns_r, (-48.5, 0, zr), scale=1.0, seed=i + 90)
    return m


# ------------------------------------------------------------------------------------------------
# D4_GeyserVent — producer "Geyser Pump"
# ------------------------------------------------------------------------------------------------

VENT_PROFILE = [(6.0, 0.0), (5.4, 1.2), (4.2, 2.6), (2.8, 3.6), (2.3, 3.9), (1.7, 3.8), (1.4, 3.0), (0.0, 3.0)]
BENCH_Z = -7.0  # pump bench centre (local z)
BENCH_TOP = 2.6


def build_geyser_vent():
    """
    Producer "Geyser Pump": a stone vent mound with a teal mineral lip and a bobbing water Column
    (crown + droplets), boulders and a stake-and-rope ring; a bamboo pump pipe arches from the
    mound to a spout over a log bench where three pebble nukes get their steam bath.
    """
    m = Model("D4_GeyserVent", "vent mound centre on the floor; pump bench toward -Z (road)", budget=4500)
    rock = m.piece("Rock", STONE)
    dark = m.piece("RockDark", STONE_DARK)
    rim = m.piece("Rim", SINTER_TEAL)
    column = m.piece("Column", WATER, material="Smooth")
    foam = m.piece("ColumnFoam", WHITE, material="Smooth")
    steam = m.piece("Steam", STEAM_WHITE, material="Smooth")
    pipe = m.piece("Pipe", BAMBOO)
    pipe_nodes = m.piece("PipeNodes", BAMBOO_DARK, material="StudsSmall")
    logp = m.piece("Logs", BARK)
    stakes = m.piece("Stakes", BARK_DARK, material="StudsSmall")
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    pebbles = m.piece("Pebbles", PEBBLE, material="StudsSmall")
    ambers = [m.piece(f"Amber{k}", AMBER, material="Neon") for k in (1, 2, 3)]
    puffs = m.piece("Puffs", STEAM_WHITE, material="Smooth")
    stone_mound(rock, [(0.0, 0.0)] + VENT_PROFILE[:-1] + [(0.0, 3.0)])
    # Teal mineral lip round the crater (proud of the mound on every side).
    ring_tube(rim, (0, 3.92, 0), 2.0, 0.85, 0.3, segments=12)
    # Water jet from deep inside the mound (bob-safe) up to a foamy splash crown.
    water_jet(column, foam, 2.3, 10.8, 1.15, 0.8, seed=1)
    ellipsoid(steam, (1.9, 4.3, 0.8), (0.35, 0.3, 0.35), rings=3, segments=6)
    # Boulders round the foot + the stake-and-rope ring (gap at the front for the bench).
    for k, deg in enumerate((50, 110, 170, 230, 300)):
        a = math.radians(deg)
        boulder(dark, (6.1 * math.sin(a), 0.5, -6.1 * math.cos(a)), (1.2, 0.9, 1.0), seed=k + 5, floor=0.0)
    stake_pts = []
    for k in range(9):
        a = math.radians(35 + 36.25 * k)  # 35 .. 325 deg: open toward the bench (front)
        p = (7.4 * math.sin(a), 0.0, -7.4 * math.cos(a))
        stake_pts.append(p)
        bar(stakes, p, (p[0], 1.9, p[2]), 0.3)
    for p, q in zip(stake_pts, stake_pts[1:]):
        bar(rope, (p[0], 1.5, p[2]), (q[0], 1.5, q[2]), 0.12)
    # Pump bench: two stone legs + a log plank, pebble nukes along it.
    for x in (-3.4, 3.4):
        block(dark, (x, (BENCH_TOP - 0.5) / 2, BENCH_Z), (1.2, BENCH_TOP - 0.5, 1.6), bevel=0.2)
    block(logp, (0, BENCH_TOP - 0.25, BENCH_Z), (9.2, 0.5, 1.9), bevel=0.15)
    for k, x in enumerate((-2.8, 0.0, 2.8)):
        pebble_nuke(pebbles, ambers[k], pebbles, (x, BENCH_TOP, BENCH_Z + 0.1), scale=0.85, yaw=25 * k)
    # Bamboo pump pipe: from the mound flank up over to a spout above the middle pebble nuke.
    flank_y = 2.0
    r0 = _mound_radius(VENT_PROFILE, flank_y)
    start = (1.6, flank_y, -(math.sqrt(max(0.0, r0 * r0 - 1.6 * 1.6)) - 0.3))
    pts = [start, (1.6, 5.4, -4.4), (0.0, 5.4, BENCH_Z + 0.3), (0.0, 4.7, BENCH_Z + 0.3)]
    for a, b in zip(pts, pts[1:]):
        bamboo_run(pipe, pipe_nodes, a, b, 0.32, node_step=2.2)
    # A little sculpted steam cloud between the spout and the middle pebble nuke (static).
    puff(puffs, (0.0, BENCH_TOP + 1.75, BENCH_Z + 0.3), scale=0.42, seed=2)
    return m


# ------------------------------------------------------------------------------------------------
# D4_BambooPipes
# ------------------------------------------------------------------------------------------------

PIPE_Y = 1.6
PIPE_R = 0.42
PIPE_X_RIGHT = 25.4  # +X run end (the wheel riser stands at slot x 26 +- 0.5)
PIPE_X_LEFT = -20.4  # -X run end (the springs' inlet starts at slot x -20.5)


def build_bamboo_pipes():
    """Two bamboo pipe runs from the vent mound (pivot = vent centre, placed at the same CFrame):
    +X to the water-wheel riser, -X to the hot springs' inlet, on X-shaped log trestles, each end
    capped and propped so it reads finished before its destination is bought."""
    m = Model("D4_BambooPipes", "vent mound centre (place at the D4_GeyserVent CFrame); runs along +-X at y 1.6", budget=2500)
    pipe = m.piece("Pipe", BAMBOO)
    nodes = m.piece("PipeNodes", BAMBOO_DARK, material="StudsSmall")
    trestle = m.piece("Trestles", BARK_DARK)
    # Start where the mound is widest across the pipe's height (its lower edge), 0.1 clear of it.
    r_start = _mound_radius(VENT_PROFILE, PIPE_Y - PIPE_R - 0.1) + 0.1
    for direction, x_end in ((1, PIPE_X_RIGHT), (-1, PIPE_X_LEFT)):
        a = (direction * r_start, PIPE_Y, 0.0)
        b = (x_end - direction * 0.12, PIPE_Y, 0.0)
        bamboo_run(pipe, nodes, a, b, PIPE_R, node_step=3.2)
        span = abs(x_end) - r_start
        count = 3 if span > 16 else 2
        for k in range(count):
            x = direction * (r_start + span * (k + 0.6) / (count + 0.2))
            for s in (-1, 1):
                bar(trestle, (x - 0.7 * s, 0.0, -0.55), (x + 0.5 * s, PIPE_Y - 0.1, -0.55), 0.26)
                bar(trestle, (x - 0.7 * s, 0.0, 0.55), (x + 0.5 * s, PIPE_Y - 0.1, 0.55), 0.26)
            box(trestle, (x, PIPE_Y - PIPE_R - 0.12, 0), (0.5, 0.24, 1.5))
        # End cap + a stone prop under it.
        cylinder(nodes, (x_end - direction * 0.14, PIPE_Y, 0), (x_end, PIPE_Y, 0), PIPE_R + 0.1, segments=8)
        block(trestle, (x_end - direction * 0.6, (PIPE_Y - PIPE_R - 0.02) / 2, 0), (0.9, PIPE_Y - PIPE_R - 0.02, 1.0), bevel=0.1)
    return m


# ------------------------------------------------------------------------------------------------
# D4_WaterWheel
# ------------------------------------------------------------------------------------------------


def build_water_wheel():
    """
    Wooden water wheel (axle along local X, wheel in the YZ plane): rims + 12 paddles (Wheel) and
    8 + 8 spokes + hub (WheelTrim), rotationally symmetric about the axle so both spin cleanly about
    their box centres. Static: axle, A-frames with bearing blocks, a stone trough of water the wheel
    dips into, and a bamboo riser + aqueduct trough (fed by D4_BambooPipes at local z -8) spilling
    onto the top paddles. Placed yaw 90 so the wheel's face looks at the road.
    """
    m = Model("D4_WaterWheel", "ground centre under the axle; axle along local X; aqueduct riser at local z -8", budget=3000)
    wheel = m.piece("Wheel", WOOD)
    trim = m.piece("WheelTrim", BARK_DARK)
    axle = m.piece("Axle", BARK_DARK, material="StudsSmall")
    frame = m.piece("Frame", BARK)
    basin = m.piece("Basin", STONE)
    water = m.piece("Water", WATER, material="Smooth")
    riser = m.piece("Riser", BAMBOO)
    riser_nodes = m.piece("RiserNodes", BAMBOO_DARK, material="StudsSmall")
    spill = m.piece("Spill", WATER_LIGHT, material="Smooth")
    # Rims (closed rectangular rings revolved about local X).
    for x in (-0.9, 0.9):
        revolve(wheel, [(5.3, -0.15), (WHEEL_R, -0.15), (WHEEL_R, 0.15), (5.3, 0.15)], center=(x, AXLE_Y, 0), segments=16, closed=True, rot=rot_z(90))
    # Paddles: 12 boards across the rims, radial.
    for k in range(12):
        a = 2 * math.pi * k / 12
        radial = Vector((0.0, math.sin(a), math.cos(a)))
        c = Vector((0.0, AXLE_Y, 0.0)) + radial * 5.4
        box(wheel, tuple(c), (2.2, 1.2, 0.18), rot=frame_from(Vector((1, 0, 0)), radial))
    # Spokes (two sets) + hub.
    for x in (-0.9, 0.9):
        for k in range(8):
            a = 2 * math.pi * (k + 0.5) / 8
            radial = Vector((0.0, math.sin(a), math.cos(a)))
            p0 = Vector((x, AXLE_Y, 0.0)) + radial * 0.95
            p1 = Vector((x, AXLE_Y, 0.0)) + radial * 5.35
            bar(trim, tuple(p0), tuple(p1), 0.26)  # 0.26: side faces never flush with the rims' (R18)
    cylinder(trim, (-1.25, AXLE_Y, 0), (1.25, AXLE_Y, 0), 1.0, segments=10)
    cylinder(axle, (-2.7, AXLE_Y, 0), (2.7, AXLE_Y, 0), 0.42, segments=8)
    # A-frames at x = +-2.0 with bearing blocks.
    for x in (-2.0, 2.0):
        bar(frame, (x, 0.0, -3.9), (x, AXLE_Y - 0.3, -0.25), 0.5)
        bar(frame, (x, 0.0, 3.9), (x, AXLE_Y - 0.3, 0.25), 0.5)
        bar(frame, (x, 2.4, -2.75), (x, 2.4, 2.75), 0.36)
        block(axle, (x, AXLE_Y, 0), (0.8, 1.1, 1.1), bevel=0.12)
    # Stone trough + water surface (the bottom paddles dip into it).
    block(basin, (0, 0.15, 0), (3.6, 0.3, 14.4), bevel=0.08)
    for x in (-1.6, 1.6):
        block(basin, (x, 0.75, 0), (0.4, 1.5, 14.4), bevel=0.08)
    for z in (-7.0, 7.0):
        block(basin, (0, 0.75, z), (2.8, 1.5, 0.4), bevel=0.08)
    box(water, (0, 1.15, 0), (2.8, 0.2, 13.6))
    # Riser + aqueduct trough over the wheel top + a little spill blob.
    bamboo_run(riser, riser_nodes, (0, 0.0, -8.0), (0, 13.9, -8.0), 0.5, node_step=3.2)
    loft(riser, [_chute_section(Vector((0, 13.85, -8.0)), Vector((1, 0, 0)), Vector((0, 1, 0))), _chute_section(Vector((0, 13.55, -1.1)), Vector((1, 0, 0)), Vector((0, 1, 0)))])
    for z in (-6.0, -3.6):
        # bamboo bands round the aqueduct trough (proud of its floor, walls and lips)
        box(riser_nodes, (0, 13.75 - 0.3 * (z + 8.0) / 6.9, z), (2.0, 1.1, 0.3))
    ellipsoid(spill, (0, 13.5, -0.75), (0.55, 0.22, 0.45), rings=3, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# Small builds: whistles, springs, valves, steps
# ------------------------------------------------------------------------------------------------


def build_steam_whistles():
    """Bamboo manifold on two stone blocks with four tooting whistles (mouth notches, caps),
    sculpted puffs above them, one steam anchor and a pull cord."""
    m = Model("D4_SteamWhistles", "ground centre; whistles face -Z", budget=1800)
    rock = m.piece("Rock", STONE)
    pipe = m.piece("Pipe", BAMBOO)
    nodes = m.piece("PipeNodes", BAMBOO_DARK, material="StudsSmall")
    notch = m.piece("Notches", BARK_DARK, material="Smooth")
    puffs = m.piece("Puffs", STEAM_WHITE, material="Smooth")
    steam = m.piece("Steam", STEAM_WHITE, material="Smooth")
    cord = m.piece("Cord", ROPE, material="StudsSmall")
    for x in (-2.6, 2.6):
        block(rock, (x, 0.6, 0), (1.4, 1.2, 1.4), bevel=0.2)
    bamboo_run(pipe, nodes, (-3.6, 1.6, 0), (3.6, 1.6, 0), 0.4, node_step=2.4)
    for k, (x, h) in enumerate(((-2.0, 2.4), (-0.7, 3.6), (0.6, 3.0), (1.9, 4.2))):
        top = 1.6 + h
        bamboo_run(pipe, nodes, (x, 1.7, 0), (x, top, 0), 0.3, node_step=1.6)
        block(notch, (x, top - 0.8, -0.3), (0.32, 0.36, 0.1), bevel=0.0)
        puff(puffs, (x, top + 0.7, 0), scale=0.55 + 0.1 * k, seed=k)
    ellipsoid(steam, (1.9, 1.6 + 4.2 + 0.4, 0), (0.22, 0.2, 0.22), rings=3, segments=6)
    tube(cord, [(1.9, 1.6 + 4.2 - 0.4, -0.32), (2.6, 3.4, -0.5), (2.9, 2.4, -0.5)], 0.06, sides=4)
    block(cord, (2.9, 2.2, -0.5), (0.24, 0.5, 0.24), bevel=0.04)
    return m


UPPER = Vector((4.0, 0.0, 3.5))  # upper pool centre (local)
LOWER = Vector((-2.5, 0.0, -2.0))  # lower pool centre (local)
TIER_TOP = 1.6
INLET = Vector((10.15, 1.6, -1.0))  # inlet riser centre: butts D4_BambooPipes' -X end cap (slot x -20.4) at slot x -20.85


def build_hot_springs():
    """Two hot-spring pools: a raised upper pool on a rock tier ringed with boulders, spilling over a
    little cascade into a lower ground pool where a baby dino with a towel on its head is soaking.
    Ripple rings float on both pools; a bamboo inlet spout tops up the upper pool."""
    m = Model("D4_HotSprings", "ground centre; lower pool toward -Z; inlet riser at local (10.15, y, -1)", budget=2800)
    rock = m.piece("Rock", STONE)
    dark = m.piece("RockDark", STONE_DARK)
    water = m.piece("Water", WATER, material="Smooth")
    ripple = m.piece("Ripple", WATER_LIGHT, material="Smooth")
    foam = m.piece("Foam", WHITE, material="Smooth")
    steam = m.piece("Steam", STEAM_WHITE, material="Smooth")
    pipe = m.piece("Pipe", BAMBOO)
    nodes = m.piece("PipeNodes", BAMBOO_DARK, material="StudsSmall")
    baby = m.piece("Baby", BABY, material="StudsSmall")
    towel = m.piece("Towel", TOWEL, material="StudsSmall")
    face = m.piece("Face", EYE, material="Smooth")
    # Upper tier + its boulder rim + water.
    revolve(rock, [(0.0, 0.0), (5.2, 0.0), (4.8, TIER_TOP), (0.0, TIER_TOP)], center=tuple(UPPER), segments=14)
    for k in range(10):
        a = 2 * math.pi * (k + 0.2) / 10
        if abs(math.degrees(a) - 252) < 18:
            continue  # leave the spill gap toward the lower pool
        boulder(dark, (UPPER.x + 4.45 * math.cos(a), TIER_TOP + 0.2, UPPER.z + 4.45 * math.sin(a)), (0.95, 0.7, 0.9), seed=k + 100)
    disc(water, (UPPER.x, TIER_TOP - 0.05, UPPER.z), 3.95, 0.2, segments=14, bevel=0.04)
    ring_tube(ripple, (UPPER.x, TIER_TOP + 0.15 + 0.07, UPPER.z), 2.2, 0.22, 0.06, segments=12)
    # Lower pool: a boulder ring on the floor + water.
    for k in range(12):
        a = 2 * math.pi * (k + 0.5) / 12
        boulder(rock, (LOWER.x + 5.3 * math.cos(a), 0.3, LOWER.z + 5.3 * math.sin(a)), (1.05, 0.75, 0.95), seed=k + 120, floor=0.0)
    disc(water, (LOWER.x, 0.0, LOWER.z), 4.9, 0.5, segments=16, bevel=0.06)
    ring_tube(ripple, (LOWER.x + 0.6, 0.5 + 0.07, LOWER.z + 0.4), 2.6, 0.22, 0.06, segments=12)
    # Cascade from the tier's spill gap down to the lower pool, foam at its foot.
    gap = math.radians(252)
    lip = UPPER + Vector((4.6 * math.cos(gap), TIER_TOP + 0.1, 4.6 * math.sin(gap)))
    foot = UPPER + Vector((6.0 * math.cos(gap), 0.45, 6.0 * math.sin(gap)))
    d = (foot - lip).normalized()
    side = Vector((-math.sin(gap), 0.0, math.cos(gap)))
    prism(water, [tuple(lip + side * 0.8), tuple(lip - side * 0.8), tuple(foot - side * 0.9), tuple(foot + side * 0.9)], tuple(d.cross(side).normalized()), 0.14)
    for k in range(3):
        ellipsoid(foam, tuple(foot + side * (0.6 * (k - 1)) + Vector((0, 0.15, 0))), (0.38, 0.22, 0.38), rings=3, segments=6)
    ellipsoid(steam, (UPPER.x - 0.8, TIER_TOP + 1.4, UPPER.z + 0.6), (0.3, 0.25, 0.3), rings=3, segments=6)
    # Baby dino soaking in the lower pool (shoulders + head above the water), towel on its head.
    bc = LOWER + Vector((-1.4, 0.0, 0.6))
    ellipsoid(baby, (bc.x, 0.55, bc.z), (0.95, 0.65, 0.85), rings=5, segments=8)
    hc = Vector((bc.x, 1.5, bc.z - 0.35))
    ellipsoid(baby, tuple(hc), (0.72, 0.62, 0.7), rings=6, segments=9)
    ellipsoid(baby, (hc.x, hc.y - 0.2, hc.z - 0.65), (0.5, 0.36, 0.42), rings=4, segments=8)
    for s in (-1, 1):
        pt, n = surface(tuple(hc), (0.72, 0.62, 0.7), s * 30, 14)
        oriented_ellipsoid(face, tuple(pt - n * 0.03), (0.13, 0.17, 0.06), normal=tuple(n), rings=4, segments=6)
    tube(face, [(hc.x - 0.22, hc.y - 0.3, hc.z - 1.02), (hc.x, hc.y - 0.38, hc.z - 1.06), (hc.x + 0.22, hc.y - 0.3, hc.z - 1.02)], 0.04, sides=4)
    block(towel, (hc.x, hc.y + 0.62, hc.z + 0.05), (0.9, 0.24, 0.8), bevel=0.06, rot=rot_z(8))
    # Inlet spout: rises from the pipe end, crosses over the rim boulders, pours into the upper pool.
    over = UPPER + Vector((3.2, 0.0, -2.0))
    pts = [(INLET.x, 1.0, INLET.z), (INLET.x, 3.0, INLET.z), (over.x, 3.0, over.z), (over.x, 2.55, over.z)]
    for a, b in zip(pts, pts[1:]):
        bamboo_run(pipe, nodes, a, b, 0.32, node_step=2.4)
    ellipsoid(foam, (over.x, TIER_TOP + 0.16, over.z), (0.36, 0.12, 0.36), rings=3, segments=6)  # splash under the spout
    return m


def build_pressure_valves():
    """Stone plinth with a bamboo manifold, three colourful valve hand-wheels on stems, two round
    pressure gauges on posts and a little relief-valve puff."""
    m = Model("D4_PressureValves", "ground centre; gauges face -Z", budget=1800)
    rock = m.piece("Rock", STONE)
    pipe = m.piece("Pipe", BAMBOO)
    nodes = m.piece("PipeNodes", BAMBOO_DARK, material="StudsSmall")
    valves = [m.piece("ValveRed", SCARF, material="StudsSmall"), m.piece("ValveAmber", AMBER, material="StudsSmall"), m.piece("ValveTeal", VALVE_TEAL, material="StudsSmall")]
    rims = m.piece("Rims", BARK_DARK, material="StudsSmall")
    faces = m.piece("GaugeFaces", BONE, material="Smooth")
    needles = m.piece("Needles", INK_RED, material="Smooth")
    puffs = m.piece("Puffs", STEAM_WHITE, material="Smooth")
    block(rock, (0, 0.4, 0), (6.4, 0.8, 2.2), bevel=0.2)
    bamboo_run(pipe, nodes, (-3.2, 1.3, 0), (3.2, 1.3, 0), 0.42, node_step=2.1)
    for k, x in enumerate((-2.0, 0.0, 2.0)):
        top = 2.5 + 0.25 * (k % 2)
        cylinder(nodes, (x, 1.3, 0), (x, top, 0), 0.16, segments=6)
        ring_tube(valves[k], (x, top, 0), 0.62, 0.16, 0.16, segments=10)
        for j in range(2):
            a = math.pi * j / 2
            box(valves[k], (x, top, 0), (1.2 * abs(math.cos(a)) + 0.12, 0.12, 1.2 * abs(math.sin(a)) + 0.12))
        cylinder(valves[k], (x, top - 0.1, 0), (x, top + 0.14, 0), 0.18, segments=8)
    for x in (-3.9, 3.9):
        bar(rims, (x, 0.0, 0.2), (x, 2.6, 0.2), 0.24)
        cylinder(rims, (x, 3.2, 0.35), (x, 3.2, 0.05), 0.75, segments=12)
        cylinder(faces, (x, 3.2, 0.05), (x, 3.2, -0.03), 0.62, segments=12)
        bar(needles, (x, 3.2, -0.06), (x + 0.36, 3.5, -0.06), 0.08)
    puff(puffs, (2.9, 2.2, 0.3), scale=0.5, seed=4)
    return m


def build_stone_steps():
    """A mossy rock lookout: four chunky steps up the front to a 2.4-high ledge with a log bench,
    a bamboo railing round the back and sides, and ferns at its foot."""
    m = Model("D4_StoneSteps", "ground centre of the bottom step; steps climb toward +Z", budget=1800)
    rock = m.piece("Rock", STONE)
    dark = m.piece("RockDark", STONE_DARK)
    moss = m.piece("Moss", MOSS)
    logp = m.piece("Bench", BARK)
    rail = m.piece("Rail", BAMBOO, material="StudsSmall")
    ferns = m.piece("Ferns", FERN_DARK)
    for k in range(4):
        h = 0.6 * (k + 1)
        block(rock if k % 2 == 0 else dark, (0, h / 2, -2.4 + 1.2 * k), (3.4 - 0.1 * k, h, 1.2), bevel=0.12)
    block(dark, (0, 1.2, 2.8), (5.6, 2.4, 4.4), bevel=0.3)
    boulder(moss, (0.4, 2.5, 3.0), (2.4, 0.3, 1.9), seed=140)
    boulder(rock, (-2.9, 0.8, 1.6), (1.2, 1.0, 1.1), seed=141, floor=0.0)
    boulder(rock, (2.9, 0.7, 0.9), (1.0, 0.9, 1.0), seed=142, floor=0.0)
    cylinder(logp, (-1.6, 2.95, 3.9), (1.6, 2.95, 3.9), 0.38, segments=8)
    for x in (-1.2, 1.2):
        block(logp, (x, 2.62, 3.9), (0.5, 0.5, 0.6), bevel=0.08)
    posts = [(-2.6, 1.0), (-2.6, 4.8), (2.6, 4.8), (2.6, 1.0)]
    for x, z in posts:
        cylinder(rail, (x, 2.3, z), (x, 3.9, z), 0.14, segments=6)
    for (x0, z0), (x1, z1) in zip(posts, posts[1:]):
        cylinder(rail, (x0, 3.6, z0), (x1, 3.6, z1), 0.11, segments=6)
    for k, (x, z) in enumerate(((-2.6, -2.6), (2.5, -2.2))):
        fern(ferns, (x, 0, z), scale=0.9, seed=150 + k)
    return m


# ------------------------------------------------------------------------------------------------
# D4_MegaGeyser — hero
# ------------------------------------------------------------------------------------------------

MEGA_PROFILE = [(8.0, 0.0), (7.6, 2.4), (5.8, 2.6), (5.4, 4.8), (3.6, 5.0), (3.0, 7.0), (2.4, 7.2), (1.8, 7.1), (1.5, 6.6)]


def build_mega_geyser():
    """
    Hero: a three-tier mineral mound (green moss, amber sinter and teal crater terraces, all proud
    rings), water rivulets running down the tiers, a tall bobbing Column with a splash crown and
    droplets, a steam anchor, a stake-and-rope fence arc round the front and a "WHOOSH!" board.
    """
    m = Model("D4_MegaGeyser", "mound centre on the floor; fence + sign toward -Z (road)", budget=6000)
    rock = m.piece("Rock", STONE)
    moss = m.piece("Moss", MOSS)
    sinter = m.piece("Sinter", SINTER)
    teal = m.piece("Rim", SINTER_TEAL)
    streams = m.piece("Rivulets", WATER, material="Smooth")
    column = m.piece("Column", WATER, material="Smooth")
    foam = m.piece("ColumnFoam", WHITE, material="Smooth")
    steam = m.piece("Steam", STEAM_WHITE, material="Smooth")
    stakes = m.piece("Stakes", BARK_DARK, material="StudsSmall")
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    board = m.piece("Board", BONE, material="Smooth")
    letters = m.piece("Letters", LETTER_BLUE, material="Smooth")
    stone_mound(rock, [(0.0, 0.0)] + MEGA_PROFILE + [(0.0, 6.6)], segments=16)
    # Terrace carpets (each ring proud of its terrace top and edges: R18).
    ring_tube(moss, (0, 2.62, 0), 6.7, 1.75, 0.34, segments=16)
    ring_tube(sinter, (0, 5.02, 0), 4.5, 1.75, 0.34, segments=16)
    ring_tube(teal, (0, 7.2, 0), 2.1, 0.75, 0.3, segments=14)
    # Rivulets: water tubes following the profile down the slopes at four angles.
    for k, deg in enumerate((20, 115, 205, 300)):
        a = math.radians(deg)
        d = Vector((math.sin(a), 0.0, -math.cos(a)))
        path = []
        for r, y in ((2.75, 7.0), (3.35, 5.6), (4.5, 5.15), (5.6, 3.9), (6.7, 2.75), (7.75, 1.4), (8.05, 0.15)):
            path.append(tuple(d * (r + 0.14) + Vector((0, y, 0))))
        tube(streams, path, 0.18, sides=5)
    # Water jet: from deep in the crater (bob-safe) up to a big foamy splash crown.
    water_jet(column, foam, 4.2, 28.5, 1.8, 1.25, seed=3, segments=10)
    ellipsoid(steam, (2.2, 7.9, -1.2), (0.4, 0.32, 0.4), rings=3, segments=6)
    # Rope fence arc round the front (-110 .. 110 deg; the back is against the rocks / plot edge).
    pts = []
    for k in range(9):
        a = math.radians(-110 + 27.5 * k)
        p = (9.0 * math.sin(a), 0.0, -9.0 * math.cos(a))
        pts.append(p)
        bar(stakes, p, (p[0], 2.0, p[2]), 0.32)
    for p, q in zip(pts, pts[1:]):
        bar(rope, (p[0], 1.6, p[2]), (q[0], 1.6, q[2]), 0.12)
    # "WHOOSH!" board on two posts at the front-left of the fence (front-only lettering).
    sx, sz = 6.2, -9.6
    sign_frame(stakes, board, (sx, 3.4, sz), (5.6, 1.8), border=0.35, depth=0.4, posts=0.3, post_piece=stakes)
    block_text(letters, "WHOOSH!", (sx, 3.4, sz - 0.14), 0.13, 0.12)
    return m


# ------------------------------------------------------------------------------------------------
# D4_ParaPete — manager NPC (R30)
# ------------------------------------------------------------------------------------------------


def build_para_pete():
    """
    Para Pete (Manager NPC, owner R30): a lime parasaurolophus plumber on W6's shared dino body —
    a peach duck bill, a long orange tube crest, blue overalls with yellow buttons, swim-style
    goggles pushed up on his forehead and a cartoon bone wrench in his right hand. Figure ONLY;
    split into the R30 rig pieces (models/_npc_rig.py).
    """
    from models._npc_rig import rig_split

    m = Model("D4_ParaPete", "feet centre; faces -Z", budget=3000)
    skin = m.piece("Skin", PARA_LIME, material="StudsSmall")
    tail = m.piece("Tail", PARA_LIME, material="StudsSmall")
    belly = m.piece("Belly", BONE, material="StudsSmall")
    face = m.piece("Face", EYE, material="Smooth")
    shine = m.piece("Shine", WHITE, material="Smooth")
    bill = m.piece("Bill", BILL, material="StudsSmall")
    crest = m.piece("Crest", PARA_CREST, material="StudsSmall")
    overalls = m.piece("Overalls", OVERALLS, material="StudsSmall")
    buttons = m.piece("Buttons", BEAK, material="Smooth")
    goggles = m.piece("Goggles", BARK_DARK, material="StudsSmall")
    lens = m.piece("Lens", LENS, material="Smooth")
    wrench = m.piece("Wrench", BONE, material="StudsSmall")
    a = dino_biped(
        {"skin": skin, "belly": belly, "face": face, "shine": shine, "tail": tail},
        snout=0.82,
        arm_pose={"right": (28.0, 62.0)},
    )
    hc, hr = Vector(a["head"]), a["head_r"]
    tip = Vector(a["snout_tip"])
    top = a["head_top"]
    # Duck bill: a wide flat rounded plate over the snout tip.
    oriented_ellipsoid(bill, (0, tip.y - 0.05, tip.z + 0.22), (0.66, 0.5, 0.2), normal=(0, -0.25, -1), up=(0, 1, 0), rings=4, segments=10)
    # Tube crest sweeping back from the top of the head.
    tube(
        crest,
        [(0, top - 0.4, hc.z + 0.45), (0, top + 0.05, hc.z + 1.35), (0, top + 0.2, hc.z + 2.4), (0, top - 0.1, hc.z + 3.2)],
        0.34,
        sides=8,
        radii=[0.36, 0.32, 0.27, 0.16],
    )
    # Overalls: shorts band round the hips + bib on the chest + straps + buttons.
    bc = Vector(a["body_c"])
    bw, bh, bd = a["body"]
    hip = a["hip"]
    ellipsoid(overalls, (0, hip + 0.35, bc.z), (bw * 1.03, 0.62, bd * 1.03), rings=5, segments=12)
    chest = Vector(a["chest"])
    bib_z = bc.z - bd * math.sqrt(max(0.0, 1 - ((chest.y - 0.15 - bc.y) / bh) ** 2)) - 0.08
    block(overalls, (0, chest.y - 0.15, bib_z), (1.4, 1.3, 0.26), bevel=0.06)
    for s in (-1, 1):
        tube(overalls, [(s * 0.55, chest.y + 0.45, bib_z), (s * 0.85, bc.y + bh * 0.72, bc.z - 0.2), (s * 0.8, bc.y + bh * 0.6, bc.z + bd * 0.85)], 0.1, sides=4)
        ellipsoid(buttons, (s * 0.5, chest.y + 0.3, bib_z - 0.16), (0.12, 0.12, 0.06), rings=3, segments=6)
    # Goggles pushed up on the forehead: strap round the head + two lens rings.
    gy = hc.y + 0.45
    rr = hr[0] * math.sqrt(max(0.0, 1 - (0.45 / hr[1]) ** 2)) + 0.04
    ring_tube(goggles, (0, gy, hc.z), rr, 0.14, 0.18, segments=12)
    for s in (-1, 1):
        pt, n = surface(tuple(hc), hr, s * 22, 26)
        c = pt + n * 0.12
        oriented_ellipsoid(goggles, tuple(c), (0.34, 0.3, 0.12), normal=tuple(n), rings=4, segments=8)
        oriented_ellipsoid(lens, tuple(c + n * 0.08), (0.24, 0.21, 0.06), normal=tuple(n), rings=3, segments=8)
    # Bone wrench held in the right hand, pointing forward-up; an open C jaw at its tip.
    hand = Vector(a["hands"]["right"])
    w0 = hand + Vector((0.0, -0.35, 0.15))
    w1 = hand + Vector((0.15, 1.15, -0.55))
    bone(wrench, tuple(w0), tuple(w1), 0.13, knob=0.2, segments=6)
    jaw = w1 + Vector((0.05, 0.35, -0.15))
    ring_tube(wrench, tuple(jaw), 0.32, 0.18, 0.2, segments=8, axis="Z")
    rig_split(
        m,
        dino_bones(a),
        assign={"Tail": "Torso", "Crest": "Head", "Wrench": "ArmR"},
        frame=((0.0, 0.0, 0.0), 0.0),
    )
    return m


BUILDERS = {
    "D4_Floor": build_floor,
    "D4_EntryArch": build_entry_arch,
    "D4_Rocks": build_rocks,
    "D4_GeyserVent": build_geyser_vent,
    "D4_BambooPipes": build_bamboo_pipes,
    "D4_WaterWheel": build_water_wheel,
    "D4_SteamWhistles": build_steam_whistles,
    "D4_HotSprings": build_hot_springs,
    "D4_PressureValves": build_pressure_valves,
    "D4_MegaGeyser": build_mega_geyser,
    "D4_ParaPete": build_para_pete,
    "D4_StoneSteps": build_stone_steps,
}
