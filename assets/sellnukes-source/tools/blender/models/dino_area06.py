"""
dino_area06.py — Dino Valley area D6 "Volcano Reactor" (World 2 spec §6.2 / §16), the FINALE and
the most impressive Dino area: a giant tamed volcano (two meshes, VolcanoBase + VolcanoTop) with a
stone reactor door, a glowing core window, lava streaks, a west terrace and a bubbling crater; twin
lava channels from its foot turning stone water-wheel turbines; nodding magma seesaw pumps; puffing
steam vents; a glowing crystal core inside a ring of rune stones with a floating golden ring; a
basalt cliff with a lava waterfall; a rope sky bridge from a basalt spire to the volcano terrace; an
obsidian-and-gold crown on the crater rim; Chief Tyra (a T. rex in a hard hat, clipboard in her tiny
arms) — and, the finale, a GOLDEN T-REX STATUE rising from the crater on a basalt pillar, roaring
happily at the sky (crown ~66 studs up, seen across the valley).

Placement: src/shared/Config/Worlds/Dino/Layouts/Area06.luau (slot-local; docs/areas-art.md "Dino
D5-D6"). Shared Dino helpers (palette, dino_arch, fern, palm, body_shell, hard_hat, ...) come from
dino_area05.py; Chief Tyra and the statue use W6's shared body (dino_area01.dino_biped). Kid-friendly (spec §2): lava is candy-orange "warm jelly" (Smooth, never Neon,
owner R19), nothing burns, the T. rex smiles, no teeth or claws.

Models (key: pivot / notes)                                                build key
    D6_Floor           SLOT ORIGIN pivot (layout cf = identity); top y = 0.5       base
    D6_EntryArch       ground centre between the posts; "VOLCANO / REACTOR"        base
    D6_VolcanoBase     PRODUCER (part 1): volcano ground centre (slot (0, 0.5, 48)); D6_VolcanoCore
                       door -Z; Core = round core window (pulsing light); terrace
                       (west flank, y 14..14.9) takes the Sky Bridge; lava outlets
                       at x = +-7.5 feed the Lava Channel; Lamp = door torches
    D6_VolcanoTop      PRODUCER (part 2): SAME pivot as the base; y 20..38 rim;    D6_VolcanoCore
                       CoreLava = crater pool (light), Bubbles bob, SteamCloud
    D6_LavaChannel     front centre between the two troughs (slot (0, 0.5, 18));  D6_LavaChannel
                       LavaFlow* = lava strips + basins (W10 "Lava" scroll row)
    D6_StoneTurbines   ground centre under the axle; Wheel* spin X (placed twice) D6_StoneTurbines
    D6_SteamVents      ground centre of the mound; SteamA/B/C puffs                 D6_SteamVents
    D6_MagmaPumps      ground centre; Arm* seesaw nods about X (placed twice)      D6_MagmaPumps
    D6_CrystalCore     ground centre; Crystal (light), Twirl* floating ring        D6_CrystalCore
    D6_LavaFalls       ground centre of the pool; cliff toward +Z; LavaFall*       D6_LavaFalls
    D6_SkyBridge       spire foot (slot (-46, 0.5, 36)); deck lands on the terrace D6_SkyBridge
    D6_ObsidianCrown   SAME pivot as the volcano; gold ring + 8 obsidian spires     D6_ObsidianCrown
    D6_ChiefTyra       Manager: T. rex figure on a mat + reactor control podium    D6_ChiefTyra
    D6_GoldenTRex      FINALE: islet top in the crater (volcano local (0, 36.4, 0)) D6_GoldenTRex

Budgets (docs/world-art.md §4, spec §15): fully built D6 <= 34k triangles; each volcano half and the
statue <= 6k (hero); machines <= 3-5k; manager <= 3k. Height budget 140 (statue crown ~66 in slot space).
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import Model, STEEL, TOY_RED, WHITE, YELLOW
from snkit.kit import block, disc
from snkit.shapes import bar, cylinder, ellipsoid, loft, revolve, ring_tube, rot_x, rot_y, rot_z

from models._critter_kit import crown as toy_crown
from models._critter_kit import oriented_ellipsoid
from models.area01 import LOT_TOP, SLOT_PIVOT, lot_stripes
from models.area04 import Xf, _hash
from models.area09 import cable
from models.dino_area01 import dino_biped, dino_bones
from models.dino_area05 import (
    AMBER,
    AMBER_LIGHT,
    BASALT,
    BASALT_LIGHT,
    BLUSH,
    BONE,
    EYE,
    FERN,
    FERN_DARK,
    GOLD,
    GOLD_DARK,
    GOLD_LIGHT,
    LAVA,
    LAVA_LIGHT,
    LOG,
    LOG_DARK,
    LOG_LIGHT,
    MOSS,
    OBSIDIAN,
    ROPE,
    SHINE,
    STONE_DARK,
    STONE_LIGHT,
    STONE_WARM,
    THATCH,
    boulder,
    back_bumps,
    biped_geometry,
    body_shell,
    clipboard,
    dino_arch,
    fern,
    hard_hat,
    palm,
    place_new,
    ribbon,
)

T = LOT_TOP
SLOT_W = 104.0
SLOT_D = 70.0
TYRA = (236, 104, 92)  # Chief Tyra: friendly coral T. rex (Para Pete is the green one)
ROCK = (156, 112, 88)  # warm brown volcano rock (cooler greys read purple under Roblox lighting)
ROCK_DARK = (118, 84, 70)
ASH = (156, 132, 116)  # D6 ground: warm ash
ASH_DARK = (138, 116, 104)
CRYSTAL = (124, 240, 228)  # crystal core (Smooth: R19, big glows are never Neon)

# ------------------------------------------------------------------------------------------------
# Volcano shape (shared by VolcanoBase / VolcanoTop / ObsidianCrown / SkyBridge / LavaChannel, so the
# separately built pieces always meet exactly). Volcano-local frame: ground centre, door toward -Z.
# Angles: x = r cos(a), z = r sin(a); the door faces a = 270 deg.
# ------------------------------------------------------------------------------------------------

VOLCANO_SLOT = (0.0, 48.0)  # slot (x, z) of the volcano pivot (layout VOLCANO)
SEG = 28
# Classic squat cartoon volcano (Studio check: a taller profile read as a chimney): a wide flared
# foot (concave flank) narrowing to a broad crater rim; base diameter 39, rim 38 up.
PROFILE = [
    (0.0, 19.5), (2.0, 17.9), (5.0, 16.0), (9.0, 14.0), (14.0, 12.0), (20.0, 10.4), (26.0, 9.2),
    (32.0, 8.4), (36.0, 8.05), (38.0, 7.95),
]
SPLIT_Y = 20.0  # VolcanoBase / VolcanoTop seam (hidden under the base's rock collar)
RIM_Y = 38.0  # flat crater rim top (the Obsidian Crown ring sits on it)
RIM_IN = 0.84  # inner rim radius / outer rim radius
POOL_Y = 35.45  # crater lava pool top
ISLET_TOP = 36.4  # the islet's flat top = Golden T-Rex pivot
LEDGE_Y0, LEDGE_Y1 = 14.0, 14.9  # west terrace slab (Sky Bridge landing)
LEDGE_OUT = 2.4  # terrace reach beyond the cone surface
LEDGE_ARC = (150.0, 245.0)  # degrees covered by the terrace
SPIRE_SLOT = (-46.0, 36.0)  # Sky Bridge spire foot (layout SKY_SPIRE)
BRIDGE_A = math.degrees(math.atan2(SPIRE_SLOT[1] - VOLCANO_SLOT[1], SPIRE_SLOT[0] - VOLCANO_SLOT[0])) % 360.0
OUTLET_X = 7.5  # lava outlets / channels / turbines at volcano-local x = +-7.5


def _lumps(a: float) -> float:
    """Angular lumpiness of the cone (deterministic): radius multiplier around 1."""
    return 1.0 + 0.045 * math.sin(3 * a + 0.4) + 0.03 * math.sin(7 * a + 1.1) + 0.02 * math.sin(11 * a + 2.0)


def profile_r(y: float) -> float:
    """Mean cone radius at height y (linear in PROFILE)."""
    for (y0, r0), (y1, r1) in zip(PROFILE, PROFILE[1:]):
        if y <= y1:
            return r0 + (r1 - r0) * (y - y0) / (y1 - y0)
    return PROFILE[-1][1]


def vr(a: float, y: float) -> float:
    """Volcano surface radius at angle a (radians) and height y."""
    return profile_r(y) * _lumps(a)


def vpoint(a: float, y: float, out: float = 0.0) -> Vector:
    """Point on (or `out` studs outside, measured radially) the volcano surface."""
    r = vr(a, y) + out
    return Vector((r * math.cos(a), y, r * math.sin(a)))


def vnormal(a: float, y: float) -> Vector:
    """Outward surface normal (radial + the slope's upward tilt)."""
    dr = (vr(a, y + 0.5) - vr(a, y - 0.5)) if y > 0.5 else (vr(a, 1.0) - vr(a, 0.0))
    return Vector((math.cos(a), -dr, math.sin(a))).normalized()


def vring(y: float, out: float = 0.0, scale: float = 1.0):
    """One loft section: SEG points round the cone at height y (`out` radial offset, `scale` x radius)."""
    pts = []
    for i in range(SEG):
        a = 2 * math.pi * i / SEG
        r = vr(a, y) * scale + out
        pts.append((r * math.cos(a), y, r * math.sin(a)))
    return pts


def _outlet_front_z() -> float:
    """Volcano-local z of the lava outlets' front faces (x = +-OUTLET_X); the channel ends 0.15 short."""
    a = math.atan2(-math.sqrt(19.5**2 - OUTLET_X**2), OUTLET_X)
    r = vr(a, 0.0)
    return -math.sqrt(max(r * r - OUTLET_X**2, 1.0)) - 1.7


OUTLET_Z = _outlet_front_z()
CHANNEL_SLOT_Z = 18.0  # layout CHANNEL (basin centres)
CHANNEL_LEN = VOLCANO_SLOT[1] + OUTLET_Z - 0.15 - CHANNEL_SLOT_Z  # basin centre -> trough end


def _band(piece, y0, y1, out, inner=0.03):
    """
    Closed rock band hugging the cone between y0..y1, `out` studs proud. Its inner face floats a
    hairline (`inner` = 0.03) off the cone (vring samples the same angles as the cone lofts and the
    profile is linear between knots, so it follows the facets exactly): the seam collar over
    VolcanoTop never cuts into the top mesh's volume (owner R24); its top face hides the hairline.
    """
    a0 = vring(y0, inner)
    sections = [a0, vring(y0, out), vring(y1, out), vring(y1, inner), a0]
    loft(piece, sections, cap_start=False, cap_end=False)


def _streak(piece, a_deg, y_top, y_bot, w_top, w_bot, steps=9):
    """Candy-lava streak running down the cone surface along angle a (0.12 proud of the surface)."""
    a = math.radians(a_deg)
    path, normals, widths = [], [], []
    for i in range(steps + 1):
        t = i / steps
        y = y_top + (y_bot - y_top) * t
        wob = 1.5 * math.sin(y * 0.16 + a_deg)  # by height, so base + top streaks line up
        aa = a + wob / max(vr(a, y), 1.0)
        n = vnormal(aa, y)
        path.append(tuple(vpoint(aa, y) + n * 0.14))
        normals.append(tuple(n))
        widths.append(w_top + (w_bot - w_top) * t)
    ribbon(piece, path, normals, widths, thick=0.14)


# ------------------------------------------------------------------------------------------------
# D6 base: floor + entry arch
# ------------------------------------------------------------------------------------------------


def build_floor():
    """
    Volcano Reactor ground (slot-origin pivot): two-tone basalt stripes, warm flagstones from the road
    to the volcano door, zig-zag candy-lava cracks on both sides (Smooth, flat decals), a low basalt
    wall with moss caps on the sides and back, obsidian boulders, ferns and two back-corner palms.
    """
    m = Model("D6_Floor", SLOT_PIVOT, budget=4500)
    ground = m.piece("Ash", ASH)
    ground2 = m.piece("AshDark", ASH_DARK)
    path = m.piece("Flagstones", STONE_WARM)
    cracks = m.piece("LavaCracks", LAVA_LIGHT, material="Smooth")
    wall = m.piece("Wall", ROCK_DARK)
    moss = m.piece("Moss", MOSS)
    rocks = m.piece("Obsidian", OBSIDIAN, material="StudsSmall")
    leaves = m.piece("Ferns", FERN)
    trunk = m.piece("Trunks", LOG)
    palm_leaves = m.piece("PalmLeaves", FERN_DARK)
    nuts = m.piece("Coconuts", LOG_DARK, material="StudsSmall")
    lot_stripes(ground, ground2, -SLOT_W / 2, SLOT_W / 2, 0.0, SLOT_D, stripe=13.0, top=T, along="z")
    # Flagstones (top T + 0.1): pairs of slabs from the road up to the door steps (slot z ~25).
    z, i = 1.6, 0
    while z < 24.0:
        for sx in (-1, 1):
            w = 2.6 + 0.5 * _hash(i, sx)
            d = 2.0 + 0.4 * _hash(i + 9, sx)
            block(path, (sx * 1.55 + (_hash(i, 3) - 0.5) * 0.3, T + 0.05, z), (w, 0.1, d), bevel=0.0, rot=rot_y((_hash(i, sx + 5) - 0.5) * 10))
        z += 2.7
        i += 1
    # Lava cracks: flat zig-zags (top T + 0.07) on the open ground left and right.
    # (Free ground only: between the volcano, the pumps / vents and the back builds.)
    for x0, z0, x1, z1 in ((22.0, 34.0, 27.0, 45.0), (-21.0, 32.0, -27.0, 45.0), (12.0, 30.0, 20.0, 37.5), (-12.0, 30.0, -19.0, 36.5), (22.0, 64.0, 30.0, 67.5), (-24.0, 64.0, -31.0, 67.5)):
        d = Vector((x1 - x0, 0, z1 - z0))
        length = d.length
        d.normalize()
        perp = Vector((-d.z, 0, d.x))
        pts, n = [], 6
        for j in range(n + 1):
            p = Vector((x0, T + 0.07, z0)) + d * (length * j / n) + perp * ((1 if j % 2 else -1) * 0.9 * (1 - 0.5 * j / n))
            pts.append(tuple(p))
        ribbon(cracks, pts, [(0, 1, 0)] * len(pts), [0.9 - 0.5 * (j / n) for j in range(n + 1)], thick=0.07)
    # Low basalt wall (back + sides from z 20), moss caps proud by 0.1.
    wh = 2.0
    for x0, x1 in ((-52, -26), (-26, 0), (0, 26), (26, 52)):
        block(wall, ((x0 + x1) / 2, T + wh / 2, SLOT_D - 0.7), (x1 - x0, wh, 1.4), bevel=0.3)
        block(moss, ((x0 + x1) / 2, T + wh + 0.15, SLOT_D - 0.7), (x1 - x0 - 0.6, 0.3, 1.6), bevel=0.1)
    for sx in (-1, 1):
        x = sx * (SLOT_W / 2 - 0.7)
        for z0, z1 in ((20.0, 45.0), (45.0, SLOT_D - 1.4)):
            block(wall, (x, T + wh / 2, (z0 + z1) / 2), (1.4, wh, z1 - z0), bevel=0.3)
            block(moss, (x, T + wh + 0.15, (z0 + z1) / 2), (1.6, 0.3, z1 - z0 - 0.6), bevel=0.1)
    # Obsidian boulders + ferns along the walls; palms in the back corners.
    for k, (x, z, s) in enumerate(((49.0, 21.5, 1.2), (-49.0, 21.5, 1.3), (49.0, 46.0, 0.9), (-49.0, 46.0, 1.0))):
        boulder(rocks, (x, T + 0.5 * s, z), (1.3 * s, 0.9 * s, 1.1 * s), seed=k * 3 + 1)
    for k, (x, z) in enumerate(((48.5, 22.5), (-46.5, 24.5), (25.0, 66.5), (-25.0, 66.5), (48.0, 34.0))):
        fern(leaves, (x, T, z), size=1.0, fronds=5, seed=k * 5 + 3)
    for k, (x, z, lean) in enumerate(((47.0, 64.5, -8.0), (-47.0, 64.5, 8.0))):
        palm(trunk, palm_leaves, nuts, (x, T, z), height=12.5, lean=lean, seed=k * 7 + 1)
    return m


def _volcano_crest(m, info):
    """D6 arch crest: a mini volcano on the board top with a candy-lava cap and two drips (both faces)."""
    rock = m.piece("Crest", ROCK)
    lava = m.piece("CrestLava", LAVA_LIGHT, material="Smooth")
    y0 = info["top_y"] - 0.2
    revolve(rock, [(0.0, y0), (3.4, y0), (2.6, y0 + 1.6), (1.4, y0 + 3.4), (0.0, y0 + 3.2)], segments=12)
    revolve(lava, [(0.0, y0 + 3.35), (1.45, y0 + 3.35), (1.62, y0 + 3.55), (0.0, y0 + 3.75)], segments=12)
    for sx, sz in ((-1, -1), (1, 1)):
        a = math.atan2(sz, sx * 0.5)
        pts = [(math.cos(a) * r, y, math.sin(a) * r) for r, y in ((1.5, y0 + 3.3), (2.0, y0 + 2.4), (2.55, y0 + 1.6), (3.05, y0 + 0.75))]
        ribbon(lava, pts, [(math.cos(a) * 0.8, 0.6, math.sin(a) * 0.8)] * 4, [0.8, 0.7, 0.6, 0.5], thick=0.12)
        pts2 = [(-p[0], p[1], -p[2]) for p in pts]
        ribbon(lava, pts2, [(-math.cos(a) * 0.8, 0.6, -math.sin(a) * 0.8)] * 4, [0.8, 0.7, 0.6, 0.5], thick=0.12)


def build_entry_arch():
    """'VOLCANO / REACTOR' arch: basalt dino_arch, candy-lava letters, a mini-volcano crest."""
    return dino_arch(
        "D6_EntryArch",
        ["VOLCANO", "REACTOR"],
        inner=20.0,
        budget=6000,
        max_cell=0.46,
        letter_color=LAVA_LIGHT,
        stone_colors=(ROCK, ROCK_DARK),
        topper=_volcano_crest,
    )


# ------------------------------------------------------------------------------------------------
# Producer: the volcano (two meshes)
# ------------------------------------------------------------------------------------------------


def build_volcano_base():
    """
    Volcano base (y 0..20): a lumpy, flared rock cone with a darker strata band, a rock collar over the
    seam to the top mesh, a west terrace with a rope railing (the Sky Bridge lands on it), the
    reactor door (stone portal, wooden double door with bone handles, steps, two torches = Lamp),
    a round glowing core window above the door (Core), two lava outlets at the foot feeding the
    Lava Channel, candy-lava streaks, boulders and ferns round the foot.
    """
    m = Model(
        "D6_VolcanoBase",
        f"ground centre (layout: slot (0, 0.5, 48)); door faces -Z; terrace y {LEDGE_Y0}..{LEDGE_Y1} on the west flank "
        f"(bridge angle {BRIDGE_A:.1f} deg); outlets at x = +-{OUTLET_X} front z {OUTLET_Z:.2f}; Core = core window",
        budget=6000,
    )
    rock = m.piece("Rock", ROCK)
    strata = m.piece("Strata", ROCK_DARK)
    ledge = m.piece("Terrace", STONE_WARM)
    rail = m.piece("Railing", LOG)
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    stone = m.piece("Portal", STONE_LIGHT)
    door = m.piece("Door", LOG_DARK)
    bone = m.piece("Handles", BONE, material="StudsSmall")
    core = m.piece("Core", LAVA_LIGHT, material="Smooth")
    lava = m.piece("LavaStreaks", LAVA_LIGHT, material="Smooth")
    lamp = m.piece("Lamp", AMBER_LIGHT, material="Neon")
    leaves = m.piece("Ferns", FERN)
    boulders = m.piece("Boulders", BASALT_LIGHT)
    moss_patches = m.piece("Moss", MOSS)
    ys = [0.0, 1.0, 2.5, 4.5, 7.0, 10.0, 13.0, 16.5, SPLIT_Y]
    loft(rock, [vring(y) for y in ys], cap_start=True, cap_end=True)
    _band(strata, 7.4, 8.8, 0.28)
    _band(strata, SPLIT_Y - 0.7, SPLIT_Y + 0.9, 0.42)
    # West terrace: an arc slab round the cone (outer edge LEDGE_OUT beyond the surface) + railing.
    a0, a1 = (math.radians(d) for d in LEDGE_ARC)
    n = 16
    inner_lo, outer_lo, outer_hi, inner_hi = [], [], [], []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        ri = vr(a, LEDGE_Y0) - 0.5
        ro = vr(a, LEDGE_Y0) + LEDGE_OUT
        inner_lo.append((ri * math.cos(a), LEDGE_Y0, ri * math.sin(a)))
        outer_lo.append((ro * math.cos(a), LEDGE_Y0, ro * math.sin(a)))
        outer_hi.append((ro * math.cos(a), LEDGE_Y1, ro * math.sin(a)))
        inner_hi.append((ri * math.cos(a), LEDGE_Y1, ri * math.sin(a)))
    # Loft along the arc: each section is the slab's cross-section at one angle.
    loft(ledge, [[inner_lo[i], outer_lo[i], outer_hi[i], inner_hi[i]] for i in range(n + 1)])
    gap = math.radians(13.0)
    rail_pts = []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        if abs(a - math.radians(BRIDGE_A)) < gap:
            continue
        ro = vr(a, LEDGE_Y0) + LEDGE_OUT - 0.35
        p = (ro * math.cos(a), LEDGE_Y1, ro * math.sin(a))
        if i % 2 == 0:
            cylinder(rail, p, (p[0], LEDGE_Y1 + 2.0, p[2]), 0.17, segments=5)
        rail_pts.append((p[0], LEDGE_Y1 + 1.75, p[2]))
    # Rope rail in two runs (either side of the bridge gap).
    run = []
    for p in rail_pts + [None]:
        if p is not None and (not run or (Vector(p) - Vector(run[-1])).length < 3.5):
            run.append(p)
            continue
        for q0, q1 in zip(run, run[1:]):
            bar(rope, q0, q1, 0.1)
        run = [p] if p is not None else []
    # Reactor door (front, a = 270 deg): stone portal + round-top double door + steps.
    af = math.radians(270.0)
    zf = -vr(af, 2.0)
    # (Portal top y 12.95 stays under the core window's bottom edge, y 14, seen from the road.)
    for sx in (-1, 1):
        block(stone, (sx * 4.25, 3.9, zf + 0.3), (1.8, 7.8, 3.4), bevel=0.3)
    revolve(stone, [(3.3, -1.7), (5.15, -1.7), (5.15, 1.7), (3.3, 1.7)], center=(0, 7.8, zf + 0.3), segments=14, closed=True, rot=rot_x(90))
    block(door, (0, 3.9, zf - 0.85), (6.8, 7.8, 1.0), bevel=0.15)
    revolve(door, [(0.0, -0.5), (3.4, -0.5), (3.4, 0.5), (0.0, 0.5)], center=(0, 7.8, zf - 0.85), segments=14, rot=rot_x(90))
    bar(stone, (0, 0.1, zf - 1.45), (0, 10.9, zf - 1.45), 0.18)
    for sx in (-1, 1):
        bar(bone, (sx * 0.65, 3.4, zf - 1.5), (sx * 0.65, 5.2, zf - 1.5), 0.18)
        ellipsoid(bone, (sx * 0.65, 3.35, zf - 1.5), (0.26, 0.26, 0.26), rings=3, segments=5)
        ellipsoid(bone, (sx * 0.65, 5.25, zf - 1.5), (0.26, 0.26, 0.26), rings=3, segments=5)
    for k in range(3):
        block(stone, (0, 0.18 + 0.32 * k, zf - 2.3 - (2 - k) * 0.95 + 0.6), (8.6 - k * 0.8, 0.36, 1.2 + (2 - k) * 0.95), bevel=0.1)
    # Core window above the door: frame ring + glowing candy-lava disc, tilted to the slope.
    cy = 16.6
    nrm = vnormal(af, cy)
    cpos = vpoint(af, cy) + nrm * 0.25
    from models._critter_kit import circle_points, tube

    oriented_ellipsoid(core, tuple(cpos), (2.6, 2.6, 0.22), normal=tuple(nrm), rings=4, segments=14)
    pts = circle_points(tuple(cpos + nrm * 0.05), 2.85, normal=tuple(nrm), segments=14, up=(0, 1, 0))
    tube(stone, pts, 0.42, sides=5, closed=True)
    # Torches (Lamp: one soft light between them) on log posts beside the steps.
    for sx in (-1, 1):
        x, z = sx * 5.2, zf - 2.4
        cylinder(rail, (x, 0, z), (x, 4.6, z), 0.3, segments=6)
        revolve(stone, [(0.0, 0.0), (0.45, 0.0), (0.85, 0.6), (0.75, 0.75), (0.0, 0.75)], center=(x, 4.5, z), segments=8)
        ellipsoid(lamp, (x, 5.75, z), (0.55, 0.85, 0.55), rings=4, segments=6)
    # Lava outlets at the foot (x = +-7.5): stone hoods with a lava tongue spilling to the channel.
    for sx in (-1, 1):
        x = sx * OUTLET_X
        # Hood: front face exactly at OUTLET_Z (the channel trough ends 0.15 in front of it).
        block(stone, (x, 1.5, OUTLET_Z + 1.3), (3.6, 3.0, 2.6), bevel=0.3)
        oriented_ellipsoid(rock, (x, 1.75, OUTLET_Z - 0.02), (1.15, 0.75, 0.12), normal=(0, 0, -1), rings=3, segments=10)
        block(lava, (x, 1.0, OUTLET_Z + 0.5), (2.0, 0.24, 1.1), bevel=0.0)
    # Lava streaks down the flanks (front diagonals + back), from the collar to the ground.
    for a_deg in (300.0, 330.0, 20.0, 110.0, 140.0):
        _streak(lava, a_deg, SPLIT_Y - 1.0, 0.6, 1.9, 1.2)
    # Moss patches low on the flanks (flattened lumps hugging the surface).
    for k, deg in enumerate((5.0, 60.0, 95.0, 175.0, 250.0, 285.0, 350.0)):
        a = math.radians(deg)
        y = 2.5 + 3.0 * _hash(k, 9)
        n = vnormal(a, y)
        oriented_ellipsoid(moss_patches, tuple(vpoint(a, y) + n * 0.05), (2.2, 1.3, 0.35), normal=tuple(n), rings=3, segments=8)
    # Boulders and ferns round the foot (keeping the door, the outlets and the terrace foot clear).
    # (Nothing on the back arc 40..140 deg: the foot runs close to the back wall there.)
    for k, deg in enumerate((10.0, 35.0, 145.0, 165.0, 205.0, 228.0, 318.0, 345.0)):
        a = math.radians(deg)
        p = vpoint(a, 0.0, 0.9)
        boulder(boulders, (p.x, 1.15, p.z), (1.6, 1.1, 1.4), seed=k * 4 + 2)
        if k % 2 == 0:
            q = vpoint(a + 0.12, 0.0, 1.6)
            fern(leaves, (q.x, 0.0, q.z), size=1.0, fronds=5, seed=k * 3 + 1)
    return m


def build_volcano_top():
    """
    Volcano top (y 20..38, SAME pivot as the base): the upper cone up to a flat crater rim, a crater
    wall down to a glowing candy-lava pool (CoreLava: pulsing light) around a rock islet (the Golden
    T-Rex pillar stands on it), bobbing lava Bubbles, overflow streaks continuing the base's, rock
    outcrops and a cartoon smoke cloud drifting off the back rim (SteamCloud).
    """
    m = Model(
        "D6_VolcanoTop",
        f"SAME pivot as D6_VolcanoBase (volcano ground centre); rim top y {RIM_Y}; pool top y {POOL_Y}; "
        f"islet top y {ISLET_TOP} = D6_GoldenTRex pivot; CoreLava = crater light; SteamCloud particles",
        budget=6000,
    )
    rock = m.piece("Rock", ROCK)
    rim = m.piece("Rim", ROCK_DARK)
    pool = m.piece("CoreLava", LAVA_LIGHT, material="Smooth")
    bubbles = m.piece("Bubbles", LAVA, material="Smooth")
    lava = m.piece("LavaStreaks", LAVA_LIGHT, material="Smooth")
    islet = m.piece("Islet", BASALT_LIGHT)
    outcrop = m.piece("Outcrops", BASALT_LIGHT)
    steam = m.piece("SteamCloud", (238, 236, 242), material="Smooth")
    ys = [SPLIT_Y, 23.0, 26.0, 29.0, 32.0, RIM_Y - 2.0]
    outer = [vring(y) for y in ys]
    loft(rock, outer, cap_start=True, cap_end=False)
    # Rim: outer lip up to the flat top, across, then the crater wall down to the floor (closed).
    lip = vring(RIM_Y)
    top_in = vring(RIM_Y, scale=RIM_IN)
    wall_mid = vring(POOL_Y + 0.6, scale=0.74)
    floor = vring(POOL_Y - 0.9, scale=0.7)
    loft(rim, [vring(RIM_Y - 2.0), lip, top_in, wall_mid, floor], cap_start=False, cap_end=True)
    # Lava pool: annulus from the islet to just inside the crater wall (top POOL_Y).
    pool_out = [(x, POOL_Y, z) for x, _, z in vring(POOL_Y + 0.6, scale=0.755)]  # tucked 0.1 into the wall
    pool_in = [(2.75 * math.cos(2 * math.pi * i / SEG), POOL_Y, 2.75 * math.sin(2 * math.pi * i / SEG)) for i in range(SEG)]
    low_out = [(x, POOL_Y - 0.3, z) for x, _, z in pool_out]
    low_in = [(x, POOL_Y - 0.3, z) for x, _, z in pool_in]
    loft(pool, [pool_in, pool_out, low_out, low_in, pool_in], cap_start=False, cap_end=False)
    revolve(islet, [(0.0, POOL_Y - 0.8), (2.95, POOL_Y - 0.8), (2.85, POOL_Y + 0.4), (2.3, ISLET_TOP - 0.02), (0.0, ISLET_TOP + 0.08)], segments=14)
    for k in range(6):
        a = math.radians(30 + 60 * k + 12 * _hash(k, 2))
        r = 3.6 + 1.4 * _hash(k, 5)
        ellipsoid(bubbles, (r * math.cos(a), POOL_Y + 0.05, r * math.sin(a)), (0.42, 0.3, 0.42), rings=4, segments=6)
    # Overflow streaks from the rim down to the base collar (same angles as the base streaks).
    for a_deg in (300.0, 330.0, 20.0, 110.0, 140.0):
        _streak(lava, a_deg, RIM_Y - 0.3, SPLIT_Y + 1.05, 1.6, 1.8, steps=8)  # collar top is SPLIT_Y + 0.9
    # Rock outcrops half-sunk into the upper cone (between the streaks).
    for k, (deg, y) in enumerate(((255.0, 24.0), (355.0, 28.0), (75.0, 23.0), (180.0, 27.0), (225.0, 31.0), (40.0, 33.0))):
        a = math.radians(deg)
        p = vpoint(a, y, 0.35)
        boulder(outcrop, tuple(p), (1.5, 1.1, 1.5), seed=k * 6 + 4, rings=4, segments=6)
    # Cartoon steam puffs rising off the pool (back-left, between two crown spires, under the statue
    # plinth): the WorldFx Steam emitter sits at their centre.
    a = math.radians(135.0)
    base = Vector((math.cos(a) * 5.0, POOL_Y + 0.9, math.sin(a) * 5.0))
    for dx, dy, dz, r in ((0.0, 0.0, 0.0, 1.2), (0.5, 1.2, -0.3, 1.0), (-0.4, 2.1, 0.3, 0.8)):
        ellipsoid(steam, (base.x + dx, base.y + dy, base.z + dz), (r, r * 0.85, r), rings=4, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# Lava channel + turbines + pumps + vents
# ------------------------------------------------------------------------------------------------

TROUGH_W = 3.0  # outer width; walls 0.45 thick, lava strip between them
LAVA_TOP = 1.05  # lava surface in the troughs (channel-local y)


def build_lava_channel():
    """
    Lava Channel: two stone troughs (x = +-7.5) from round lava basins at the front (local z 0) back to
    the volcano's foot outlets (they end 0.15 short of the outlet hoods). The candy-lava strips run
    along local Z (LavaFlow*: W10's "Lava" scroll row makes them flow); bubbles on the basins.
    """
    L = CHANNEL_LEN
    m = Model("D6_LavaChannel", f"front centre between the basins (layout: slot (0, 0.5, {CHANNEL_SLOT_Z})); troughs along +Z, length {L:.2f}", budget=3000)
    stone = m.piece("Trough", STONE_WARM)
    stone2 = m.piece("TroughDark", STONE_DARK)
    lava = m.piece("LavaFlow", LAVA_LIGHT, material="Smooth")
    bubbles = m.piece("Bubbles", LAVA, material="Smooth")
    hw = TROUGH_W / 2
    for sx in (-1, 1):
        x = sx * OUTLET_X
        z0, z1 = 2.0, L
        # Floor 0.06 shorter at both ends and 0.12 narrower than the walls' outer faces (owner R18:
        # the walls are proud of it, never flush).
        block(stone2, (x, 0.3, (z0 + z1) / 2), (TROUGH_W - 0.12, 0.6, z1 - z0 - 0.12), bevel=0.12)
        for wx in (-1, 1):
            block(stone, (x + wx * (hw - 0.225), 0.7, (z0 + z1) / 2), (0.45, 1.4, z1 - z0), bevel=0.1)
        block(lava, (x, LAVA_TOP - 0.2, (z0 + z1) / 2 - 0.075), (TROUGH_W - 0.95, 0.4, z1 - z0 + 0.05), bevel=0.0)
        # Basin: stone ring + pool + bubbles.
        revolve(stone, [(1.7, 0.0), (2.45, 0.0), (2.45, 1.1), (2.2, 1.25), (1.75, 1.25), (1.7, 1.15)], center=(x, 0, 0), segments=16, closed=True)
        disc(stone2, (x, 0, 0), 1.9, 0.6, segments=16, bevel=0.0)
        disc(lava, (x, 0.6, 0), 1.85, 0.45, segments=16, bevel=0.0)
        for k in range(3):
            a = math.radians(40 + 120 * k)
            ellipsoid(bubbles, (x + 0.9 * math.cos(a), 1.07, 0.9 * math.sin(a)), (0.3, 0.2, 0.3), rings=3, segments=6)
    return m


WHEEL_R = 2.6
AXLE_Y = LAVA_TOP + 0.15 + WHEEL_R


def build_stone_turbine():
    """
    Stone Turbine (placed twice, astride each lava trough): two basalt A-frame posts beside the trough
    walls, a bronze axle and a stone paddle wheel dipping just above the lava. Wheel* pieces spin about
    local X as one group (all of them are symmetric about the axle, so any leader keeps the axis).
    """
    m = Model("D6_StoneTurbines", f"ground centre under the axle (layout: (+-7.5, 0.5, 24)); axle along X at y {AXLE_Y:.2f}; Wheel* spin X", budget=1500)
    frame = m.piece("Frame", BASALT_LIGHT)
    cap = m.piece("FrameCap", MOSS)
    wheel = m.piece("WheelStone", STONE_LIGHT)
    hub = m.piece("WheelHub", GOLD_DARK, material="StudsSmall")
    for sx in (-1, 1):
        x = sx * (TROUGH_W / 2 + 0.55)
        for sz in (-1, 1):
            bar(frame, (x, 0.0, sz * 1.6), (x, AXLE_Y + 0.2, sz * 0.25), 0.6)
        block(frame, (x, AXLE_Y + 0.35, 0), (0.75, 0.7, 1.1), bevel=0.12)
        block(cap, (x, AXLE_Y + 0.8, 0), (0.85, 0.24, 1.2), bevel=0.06)
    # Wheel (axis X): rim ring, 8 paddles, 4 spokes; bronze hub + axle (all centred on the axle).
    revolve(wheel, [(WHEEL_R - 0.85, -0.7), (WHEEL_R - 0.45, -0.7), (WHEEL_R - 0.45, 0.7), (WHEEL_R - 0.85, 0.7)], center=(0, AXLE_Y, 0), segments=16, closed=True, rot=rot_z(90))
    for k in range(8):
        a = k * 45.0
        r = rot_x(a)
        c = r @ Vector((0, WHEEL_R - 0.45, 0))
        block(wheel, (0, AXLE_Y + c.y, c.z), (1.5, 0.95, 0.32), bevel=0.06, rot=r)
    for k in range(4):
        r = rot_x(45.0 * k)
        d = r @ Vector((0, WHEEL_R - 0.8, 0))
        bar(wheel, (0, AXLE_Y - d.y, -d.z), (0, AXLE_Y + d.y, d.z), 0.32)
    cylinder(hub, (-TROUGH_W / 2 - 0.95, AXLE_Y, 0), (TROUGH_W / 2 + 0.95, AXLE_Y, 0), 0.22, segments=8)
    cylinder(hub, (-0.8, AXLE_Y, 0), (0.8, AXLE_Y, 0), 0.55, segments=10)
    return m


def build_steam_vents():
    """
    Steam Vents: a rocky basalt mound with three stone chimneys (7 / 5.5 / 4.2 tall), each with a
    candy-lava glow band and a cartoon steam puff on top (SteamA / SteamB / SteamC: one emitter each).
    """
    m = Model("D6_SteamVents", "ground centre of the mound; SteamA/B/C puffs (WorldFx Steam, one emitter each)", budget=2500)
    mound = m.piece("Mound", BASALT_LIGHT)
    rock = m.piece("Chimneys", STONE_DARK)
    band = m.piece("GlowBands", LAVA_LIGHT, material="Smooth")
    moss = m.piece("Moss", MOSS)
    puffs = [m.piece(f"Steam{c}", (244, 244, 248), material="Smooth") for c in "ABC"]
    revolve(mound, [(0.0, 0.0), (4.6, 0.0), (4.3, 0.6), (3.4, 1.25), (1.8, 1.6), (0.0, 1.7)], segments=12)
    for k, (x, z, sx, sy, sz) in enumerate(((-2.6, 1.6, 1.9, 1.0, 1.7), (2.8, 1.0, 1.7, 0.9, 1.9), (0.6, -2.4, 1.7, 0.8, 1.4))):
        boulder(mound, (x, 0.95, z), (sx, sy, sz), seed=k * 5 + 9)
    for k, (x, z, h, r) in enumerate(((-2.4, 1.2, 7.2, 1.15), (2.5, 0.8, 5.6, 1.0), (0.2, -2.0, 4.3, 0.85))):
        cylinder(rock, (x, 0.5, z), (x, h, z), r + 0.35, segments=9, radius_b=r)
        revolve(rock, [(r - 0.45, h - 0.05), (r + 0.3, h - 0.05), (r + 0.3, h + 0.55), (r - 0.45, h + 0.55)], center=(x, 0, z), segments=9, closed=True)
        revolve(band, [(r + 0.05, h - 1.3), (r + 0.22, h - 1.3), (r + 0.22, h - 0.6), (r + 0.05, h - 0.6)], center=(x, 0, z), segments=9, closed=True)
        block(moss, (x + r * 0.3, 1.2, z - r * 0.9), (0.9, 0.3, 0.6), bevel=0.1)
        for dx, dy, dz, rr in ((0.0, h + 1.3, 0.0, 0.95), (0.55, h + 2.25, 0.35, 0.75), (-0.35, h + 2.9, -0.2, 0.55)):
            ellipsoid(puffs[k], (x + dx, dy, z + dz), (rr, rr * 0.85, rr), rings=4, segments=7)
    return m


BEAM_Y = 6.0  # seesaw fulcrum height (pump-local): the lowest ladle (22 deg swing) clears the well rims
BEAM_HALF = 4.4


def build_magma_pump():
    """
    Magma Pump (placed twice): a stone base with two magma wells (front + back), a log A-frame
    fulcrum, and a seesaw beam with a stone ladle at each end that nods into the wells (Arm* pieces:
    WorldFx "Arm" oscillates about X; beam, ladles and hub are all symmetric about the fulcrum, so
    the group pivots there whichever piece leads), plus a bronze tank with a gauge on the side.
    """
    m = Model("D6_MagmaPumps", f"ground centre; beam along Z, fulcrum y {BEAM_Y}; Arm* nod about X", budget=2500)
    base = m.piece("Base", STONE_DARK)
    wells = m.piece("Wells", STONE_WARM)
    lava = m.piece("Magma", LAVA_LIGHT, material="Smooth")
    frame = m.piece("Frame", LOG)
    beam = m.piece("ArmBeam", LOG_LIGHT)
    ladles = m.piece("ArmLadles", STONE_LIGHT)
    hub = m.piece("ArmHub", GOLD_DARK, material="StudsSmall")
    tank = m.piece("Tank", GOLD_DARK)
    dial = m.piece("Gauge", WHITE, material="Smooth")
    needle = m.piece("Needle", TOY_RED, material="Smooth")
    block(base, (0, 0.3, 0), (3.6, 0.6, 11.0), bevel=0.15)
    for sz in (-1, 1):
        z = sz * BEAM_HALF
        revolve(wells, [(1.0, 0.6), (1.65, 0.6), (1.65, 1.6), (1.45, 1.75), (1.05, 1.75), (1.0, 1.45)], center=(0, 0, z), segments=12, closed=True)
        disc(lava, (0, 0.6, z), 1.1, 0.75, segments=12, bevel=0.0)
    # A-frame fulcrum (legs either side of the beam) + top block.
    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(frame, (sx * 1.2, 0.6, sz * 1.3), (sx * 0.75, BEAM_Y - 0.1, 0), 0.38)
    # Seesaw: symmetric beam + two hanging ladles + hub on the fulcrum axis.
    block(beam, (0, BEAM_Y, 0), (0.7, 0.6, BEAM_HALF * 2 + 0.8), bevel=0.12)
    # Each end: a rod through the beam with a ladle below and a stone knob above, sized so the
    # ArmLadles box is centred on the fulcrum (y BEAM_Y +- 2.55) -> no wobble whichever Arm* leads.
    for sz in (-1, 1):
        z = sz * BEAM_HALF
        bar(beam, (0, BEAM_Y - 1.5, z), (0, BEAM_Y + 1.5, z), 0.24)
        revolve(ladles, [(0.0, BEAM_Y - 2.55), (0.55, BEAM_Y - 2.55), (0.8, BEAM_Y - 1.6), (0.68, BEAM_Y - 1.45), (0.0, BEAM_Y - 1.75)], center=(0, 0, z), segments=10)
        ellipsoid(ladles, (0, BEAM_Y + 2.0, z), (0.55, 0.55, 0.55), rings=4, segments=8)
    cylinder(hub, (-0.95, BEAM_Y, 0), (0.95, BEAM_Y, 0), 0.32, segments=8)
    # Bronze tank on the side with a gauge facing the road.
    tx = -2.9
    cylinder(tank, (tx, 0.0, 1.6), (tx, 3.6, 1.6), 1.0, segments=10)
    revolve(tank, [(0.0, 3.55), (1.0, 3.55), (0.6, 4.2), (0.0, 4.35)], center=(tx, 0, 1.6), segments=10)
    oriented_ellipsoid(dial, (tx, 2.4, 1.6 - 1.02), (0.5, 0.5, 0.06), normal=(0, 0, -1), rings=3, segments=10)
    bar(needle, (tx, 2.4, 1.6 - 1.1), (tx + 0.28, 2.66, 1.6 - 1.1), 0.07)
    bar(tank, (tx + 0.9, 3.0, 1.6), (-1.1, 3.0, 1.6), 0.3)
    return m


# ------------------------------------------------------------------------------------------------
# Crystal core, lava falls, sky bridge, crown
# ------------------------------------------------------------------------------------------------


def _crystal(piece, base, height, radius, tilt_x=0.0, tilt_z=0.0, segs=6):
    """Hexagonal crystal: prism shaft + pointed tip, tilted (degrees) about X then Z from `base`."""
    r = rot_z(tilt_z) @ rot_x(tilt_x)
    b = Vector(base)
    shoulder = b + r @ Vector((0, height * 0.75, 0))
    tip = b + r @ Vector((0, height, 0))
    cylinder(piece, tuple(b), tuple(shoulder), radius, segments=segs)
    cylinder(piece, tuple(shoulder), tuple(tip), radius, segments=segs, radius_b=0.04)


def build_crystal_core():
    """
    Crystal Core: a two-tier stone dais with a giant glowing aqua crystal cluster (Crystal: WorldFx
    soft pulsing light; Smooth, R19), six mossy rune stones round it with amber rune dots facing out,
    and a golden ring with four amber orbs floating round the crystals (Twirl*: slow spin about Y).
    """
    m = Model("D6_CrystalCore", "ground centre of the dais; Crystal = light; Twirl* spin Y (centred on the axis)", budget=3000)
    dais = m.piece("Dais", STONE_WARM)
    dais2 = m.piece("DaisTop", STONE_LIGHT)
    crystal = m.piece("Crystal", CRYSTAL, material="Smooth")
    stones = m.piece("RuneStones", BASALT_LIGHT)
    moss = m.piece("Moss", MOSS)
    runes = m.piece("Runes", AMBER, material="Smooth")
    ring = m.piece("TwirlRing", GOLD, material="StudsSmall")
    orbs = m.piece("TwirlOrbs", AMBER_LIGHT, material="Smooth")
    revolve(dais, [(0.0, 0.0), (5.0, 0.0), (5.0, 0.8), (4.7, 0.95), (0.0, 0.95)], segments=18)
    revolve(dais2, [(0.0, 0.9), (3.6, 0.9), (3.6, 1.6), (3.35, 1.75), (0.0, 1.75)], segments=16)
    top = 1.75
    _crystal(crystal, (0, top - 0.3, 0), 12.0, 1.75)
    for k, (h, rr, tx, tz) in enumerate(((7.5, 1.05, 22, 6), (6.2, 0.95, -18, 20), (5.4, 0.85, 8, -24), (6.8, 1.0, -20, -16), (4.6, 0.8, 16, 24))):
        a = math.radians(k * 72 + 15)
        _crystal(crystal, (1.6 * math.cos(a), top - 0.3, 1.6 * math.sin(a)), h, rr, tilt_x=tx, tilt_z=tz)
    for k in range(6):
        a = math.radians(k * 60 + 30)
        x, z = 6.9 * math.cos(a), 6.9 * math.sin(a)
        yaw = -math.degrees(a) + 90
        block(stones, (x, 2.3, z), (1.6, 4.6, 1.1), bevel=0.3, rot=rot_y(yaw))
        block(moss, (x, 4.75, z), (1.7, 0.3, 1.2), bevel=0.1, rot=rot_y(yaw))
        n = Vector((math.cos(a), 0, math.sin(a)))
        for dy in (1.6, 2.6, 3.5):
            p = Vector((x, dy, z)) + n * 0.56
            oriented_ellipsoid(runes, tuple(p), (0.22, 0.22, 0.06), normal=tuple(n), rings=3, segments=6)
    revolve(ring, [(3.55, -0.2), (3.95, -0.2), (3.95, 0.2), (3.55, 0.2)], center=(0, 9.0, 0), segments=24, closed=True)
    for k in range(4):
        a = math.radians(45 + 90 * k)
        ellipsoid(orbs, (3.75 * math.cos(a), 9.0, 3.75 * math.sin(a)), (0.5, 0.5, 0.5), rings=4, segments=8)
    return m


def build_lava_falls():
    """
    Lava Falls: a stepped basalt cliff (mossy top with ferns and a small palm) with a candy-lava
    stream across its top that pours over the lip and down the front face (LavaFall: W10's "Lava"
    row) into a stone-rimmed pool at its foot, with bobbing Bubbles and a SteamA puff at the splash.
    """
    m = Model("D6_LavaFalls", "ground centre of the pool (front); cliff toward +Z (z 3..12.5, 21 tall); LavaFall* + SteamA", budget=3500)
    cliff = m.piece("Cliff", ROCK_DARK)
    cliff2 = m.piece("CliffLight", ROCK)
    moss = m.piece("Moss", MOSS)
    rim = m.piece("PoolRim", STONE_WARM)
    lava = m.piece("LavaFall", LAVA_LIGHT, material="Smooth")
    bubbles = m.piece("Bubbles", LAVA, material="Smooth")
    steam = m.piece("SteamA", (244, 244, 248), material="Smooth")
    leaves = m.piece("Ferns", FERN)
    trunk = m.piece("Trunk", LOG)
    palm_leaves = m.piece("PalmLeaves", FERN_DARK)
    nuts = m.piece("Coconuts", LOG_DARK, material="StudsSmall")
    # Cliff: three stacked, stepping-back rock tiers (alternating tones) with lumps on the sides.
    for k, (y0, h, w, z0, d) in enumerate(((0.0, 8.0, 15.0, 3.0, 9.6), (7.8, 7.2, 13.4, 3.6, 8.6), (14.8, 6.2, 11.6, 4.0, 7.8))):
        block(cliff if k % 2 == 0 else cliff2, (0, y0 + h / 2, z0 + d / 2), (w, h, d), bevel=0.8)
    for k, (x, y, z, s) in enumerate(((-7.2, 3.0, 6.0, 2.2), (7.0, 4.5, 8.5, 2.0), (-6.0, 11.0, 9.0, 1.8), (6.0, 12.5, 6.5, 1.6), (-4.8, 18.4, 7.5, 1.4))):
        boulder(cliff2 if k % 2 else cliff, (x, y, z), (s, s * 0.9, s), seed=k * 7 + 3)
    block(moss, (0, 21.1, 7.9), (11.0, 0.4, 7.2), bevel=0.15)
    for k, (x, z) in enumerate(((-3.6, 9.6), (3.4, 10.4), (4.2, 5.9))):
        fern(leaves, (x, 21.3, z), size=0.8, fronds=5, seed=k * 3 + 8)
    palm(trunk, palm_leaves, nuts, (-3.4, 21.2, 6.2), height=7.5, lean=-10.0, seed=4)
    # Lava: a stream on the top (notch) pouring over the lip, down the front faces, into the pool.
    block(lava, (0.8, 21.32, 6.6), (2.4, 0.2, 6.6), bevel=0.0)
    path = [(0.8, 21.42, 3.6), (0.8, 21.2, 2.95), (0.8, 19.0, 2.2), (0.8, 15.0, 2.25), (0.8, 13.6, 2.85), (0.8, 10.5, 1.95), (0.8, 7.5, 1.55), (0.8, 3.5, 1.3), (0.8, 0.95, 0.9)]
    normals = [(0, 1, -0.25), (0, 0.6, -1), (0, 0.05, -1), (0, 0.05, -1), (0, 0.5, -1), (0, 0.05, -1), (0, 0.05, -1), (0, 0.05, -1), (0, 0.4, -1)]
    ribbon(lava, path, normals, [2.4, 2.4, 2.2, 2.2, 2.3, 2.4, 2.6, 2.8, 3.0], thick=0.3)
    # Pool at the foot: stone rim ring + lava disc + bubbles + a splash puff.
    revolve(rim, [(3.0, 0.0), (4.2, 0.0), (4.2, 1.2), (3.9, 1.4), (3.1, 1.4), (3.0, 1.1)], center=(0.8, 0, 0.6), segments=18, closed=True)
    disc(lava, (0.8, 0, 0.6), 3.1, 0.95, segments=18, bevel=0.0)
    for k in range(4):
        a = math.radians(60 + 90 * k)
        ellipsoid(bubbles, (0.8 + 1.8 * math.cos(a), 1.0, 0.6 + 1.5 * math.sin(a)), (0.35, 0.24, 0.35), rings=3, segments=6)
    for dx, dy, dz, r in ((0.2, 2.3, 0.0, 0.9), (1.2, 2.9, -0.4, 0.7), (-0.4, 3.5, -0.2, 0.55)):
        ellipsoid(steam, (0.8 + dx, dy, 0.6 + dz), (r, r * 0.85, r), rings=4, segments=7)
    return m


SPIRE_H = LEDGE_Y1 - 0.6 + 0.1  # platform top (SPIRE_H + 0.6) sits 0.1 above the terrace top
DECK_T = 0.25


def _bridge_points():
    """
    Sky Bridge geometry in SPIRE-LOCAL coordinates: (start on the spire platform edge, end on the
    volcano terrace) at deck height. The end sits 1.2 inside the terrace's outer edge, on its top.
    """
    a = math.radians(BRIDGE_A)
    r_end = vr(a, LEDGE_Y0) + LEDGE_OUT - 1.2
    end_slot = Vector((VOLCANO_SLOT[0] + r_end * math.cos(a), LEDGE_Y1 + DECK_T / 2 + 0.1, VOLCANO_SLOT[1] + r_end * math.sin(a)))
    spire = Vector((SPIRE_SLOT[0], 0.0, SPIRE_SLOT[1]))
    end = end_slot - spire
    flat = Vector((end.x, 0, end.z)).normalized()
    start = flat * 2.6 + Vector((0, SPIRE_H + 0.6 + DECK_T / 2, 0))
    return start, end, flat


def build_sky_bridge():
    """
    Sky Bridge: a lumpy basalt spire (27 tall) with a plank lookout platform, posts, rope rail and a
    lantern, and a sagging plank rope bridge from the platform to the volcano's west terrace (it rests
    on the terrace top, 1.2 inside its edge). Lamp = lanterns (soft light).
    """
    start, end, flat = _bridge_points()
    m = Model(
        "D6_SkyBridge",
        f"spire foot (layout: slot ({SPIRE_SLOT[0]}, 0.5, {SPIRE_SLOT[1]})); deck {tuple(round(c, 2) for c in start)} -> "
        f"{tuple(round(c, 2) for c in end)} (terrace top, spire-local)",
        budget=3500,
    )
    rock = m.piece("Spire", ROCK_DARK)
    rock2 = m.piece("SpireBands", BASALT_LIGHT)
    planks = m.piece("Planks", LOG_LIGHT)
    posts = m.piece("Posts", LOG)
    rope = m.piece("Rope", ROPE, material="StudsSmall")
    lamp = m.piece("Lamp", AMBER_LIGHT, material="Neon")
    moss = m.piece("Moss", MOSS)
    # Spire: lumpy loft of 6 rings tapering upward + two lighter bands.
    secs = []
    for k, (y, r) in enumerate(((0.0, 3.8), (3.0, 3.5), (6.0, 3.25), (9.0, 3.05), (12.0, 2.85), (SPIRE_H, 2.7))):
        ring = []
        for i in range(10):
            a = 2 * math.pi * i / 10
            rr = r * (1 + 0.08 * math.sin(3 * a + k) + 0.05 * math.sin(5 * a + 2 * k))
            ring.append((rr * math.cos(a), y, rr * math.sin(a)))
        secs.append(ring)
    loft(rock, secs, cap_start=True, cap_end=True)
    for y in (4.0, 9.5):
        revolve(rock2, [(3.0, y), (3.75, y), (3.75, y + 1.0), (3.0, y + 1.0)], segments=10, closed=True)
    # Platform (planks disc), mossy rim, four posts with a rope rail, a lantern post.
    disc(planks, (0, SPIRE_H, 0), 3.4, 0.6, segments=12, bevel=0.1)
    # Moss ring under the platform: its top runs 0.1 up into the planks (never level with the spire top).
    revolve(moss, [(2.6, SPIRE_H - 0.6), (3.0, SPIRE_H - 0.6), (3.0, SPIRE_H + 0.1), (2.6, SPIRE_H + 0.1)], segments=10, closed=True)
    deck_y = SPIRE_H + 0.6
    ang0 = math.atan2(flat.z, flat.x)
    rail_pts = []
    for k in range(6):
        a = ang0 + math.radians(40 + k * 56)
        p = (3.0 * math.cos(a), deck_y, 3.0 * math.sin(a))
        cylinder(posts, p, (p[0], deck_y + 2.2, p[2]), 0.17, segments=5)
        rail_pts.append((p[0], deck_y + 1.9, p[2]))
    for q0, q1 in zip(rail_pts, rail_pts[1:]):
        bar(rope, q0, q1, 0.09)
    lp = (-flat.x * 2.2, deck_y, -flat.z * 2.2)
    cylinder(posts, lp, (lp[0], deck_y + 3.6, lp[2]), 0.2, segments=6)
    ellipsoid(lamp, (lp[0], deck_y + 3.9, lp[2]), (0.45, 0.55, 0.45), rings=4, segments=6)
    # Bridge: planks along a sagging curve, rope rails + hangers, end posts with lanterns.
    side = Vector((-flat.z, 0, flat.x))
    length = (end - start).length
    sag = 1.8
    count = int(length / 1.15)

    def at(t):
        p = start.lerp(end, t)
        p.y -= sag * 4 * t * (1 - t)
        return p

    yaw = math.degrees(math.atan2(-flat.x, -flat.z))
    for i in range(count):
        t = (i + 0.5) / count
        p = at(t)
        q0, q1 = at(max(t - 0.01, 0)), at(min(t + 0.01, 1))
        pitch = math.degrees(math.atan2(q1.y - q0.y, (Vector((q1.x, 0, q1.z)) - Vector((q0.x, 0, q0.z))).length))
        block(planks, tuple(p), (3.0, DECK_T, 0.9), bevel=0.05, rot=rot_y(yaw) @ rot_x(pitch))
    for s in (-1, 1):
        off = side * (s * 1.45)
        for t0, t1 in zip([i / 10 for i in range(10)], [(i + 1) / 10 for i in range(10)]):
            a0 = at(t0) + off + Vector((0, 1.9 - 0.6 * 4 * t0 * (1 - t0), 0))
            a1 = at(t1) + off + Vector((0, 1.9 - 0.6 * 4 * t1 * (1 - t1), 0))
            bar(rope, tuple(a0), tuple(a1), 0.1)
        for i in range(1, 10):
            t = i / 10
            b = at(t) + off
            bar(rope, tuple(b), tuple(b + Vector((0, 1.9 - 0.6 * 4 * t * (1 - t), 0))), 0.06)
    for s in (-1, 1):
        p = end + side * (s * 1.45) - flat * 0.3 - Vector((0, DECK_T / 2 + 0.1, 0))  # post feet on the terrace top
        cylinder(posts, tuple(p), tuple(p + Vector((0, 2.4, 0))), 0.2, segments=6)
        ellipsoid(lamp, tuple(p + Vector((0, 2.65, 0))), (0.32, 0.4, 0.32), rings=4, segments=6)
    return m


CROWN_SPIRES = 8


def build_obsidian_crown():
    """
    Obsidian Crown (SAME pivot as the volcano): a gold band following the crater rim (resting on the
    flat rim top, inside its edges), eight purple-black obsidian crystal spires leaning outward
    (alternating 9 / 6.5 tall, each with a small side crystal), amber gems set in the band between
    them and violet crystal glints at the tips (Crystal: soft light).
    """
    m = Model("D6_ObsidianCrown", f"SAME pivot as the volcano (ground centre); band on the rim top y {RIM_Y}", budget=3000)
    band = m.piece("Band", GOLD)
    band2 = m.piece("BandTrim", GOLD_LIGHT, material="StudsSmall")
    spires = m.piece("Spires", OBSIDIAN, material="StudsSmall")
    gems = m.piece("Gems", AMBER, material="Smooth")
    glints = m.piece("CrystalTips", (200, 150, 255), material="Neon")
    h = 0.75
    sec = [vring(RIM_Y + 0.02, -0.25), vring(RIM_Y + h, -0.25), vring(RIM_Y + h, scale=1.0, out=-1.25), vring(RIM_Y + 0.02, out=-1.25)]
    loft(band, sec + [sec[0]], cap_start=False, cap_end=False)
    trim = [vring(RIM_Y + h - 0.02, -0.35), vring(RIM_Y + h + 0.22, -0.35), vring(RIM_Y + h + 0.22, out=-1.15), vring(RIM_Y + h - 0.02, out=-1.15)]
    loft(band2, trim + [trim[0]], cap_start=False, cap_end=False)
    top = RIM_Y + h + 0.2
    for k in range(CROWN_SPIRES):
        a = 2 * math.pi * (k + 0.5) / CROWN_SPIRES
        r = vr(a, RIM_Y) - 0.75
        base = Vector((r * math.cos(a), top - 0.3, r * math.sin(a)))
        out = Vector((math.cos(a), 0, math.sin(a)))
        tall = 9.0 if k % 2 == 0 else 6.5
        lean = 14.0
        d = (Vector((0, 1, 0)) * math.cos(math.radians(lean)) + out * math.sin(math.radians(lean))).normalized()
        shoulder = base + d * (tall * 0.72)
        tip = base + d * tall
        cylinder(spires, tuple(base), tuple(shoulder), 0.95, segments=6, radius_b=0.8)
        cylinder(spires, tuple(shoulder), tuple(tip), 0.8, segments=6, radius_b=0.05)
        side = Vector((-math.sin(a), 0, math.cos(a)))
        sb = base + side * 0.7
        sd = (d + side * 0.45).normalized()
        cylinder(spires, tuple(sb), tuple(sb + sd * tall * 0.4), 0.45, segments=5, radius_b=0.04)
        ellipsoid(glints, tuple(tip + d * 0.2), (0.28, 0.4, 0.28), rings=3, segments=5)
        # Amber gem on the band between this spire and the next.
        ag = a + math.pi / CROWN_SPIRES
        gp = vpoint(ag, RIM_Y + h / 2, -0.15)
        oriented_ellipsoid(gems, tuple(gp), (0.55, 0.42, 0.18), normal=(math.cos(ag), 0, math.sin(ag)), rings=4, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# Manager + finale
# ------------------------------------------------------------------------------------------------


# T. rex proportions on the shared body: a bigger head and snout, chunky body.
TREX_BODY = {"body": (1.4, 1.55, 1.3), "head": (1.25, 1.05, 1.2), "snout": 0.95}


def build_chief_tyra():
    """
    Chief Tyra (Manager): a friendly coral T. rex on W6's shared Dino body (dino_biped) in a yellow
    hard hat (lava-orange band) and a blue vest (cream belly showing), holding a clipboard in both
    tiny arms, beside the reactor control podium (stone pedestal, big red lever, pressure gauge).
    Figure at the model origin, yaw 0. R30 rig: the clipboard rides ArmR; ArmL is the wave arm.
    """
    from models._npc_rig import rig_split

    m = Model("D6_ChiefTyra", "ground centre between the feet; Tyra faces -Z; control podium at local +X", budget=3000)
    mat = m.piece("Mat", (104, 94, 100))
    skin = m.piece("Skin", TYRA, material="Smooth")
    tail = m.piece("Tail", TYRA, material="Smooth")
    belly = m.piece("Belly", (246, 236, 196), material="Smooth")
    face = m.piece("Face", EYE, material="Smooth")
    shine = m.piece("Shine", SHINE, material="Smooth")
    bumps = m.piece("Bumps", (196, 72, 70), material="Smooth")
    vest = m.piece("Vest", (52, 104, 196))
    hat = m.piece("Hat", YELLOW)
    hat_band = m.piece("HatBand", LAVA)
    board = m.piece("Clipboard", LOG_DARK)
    paper = m.piece("ClipPaper", WHITE, material="Smooth")
    podium = m.piece("Podium", STONE_WARM)
    lever = m.piece("Lever", STEEL, material="StudsSmall")
    knob = m.piece("LeverKnob", TOY_RED)
    gauge = m.piece("GaugeFace", (250, 244, 228), material="Smooth")
    block(mat, (1.8, 0.06, 0), (7.4, 0.12, 4.4), bevel=0.04)  # thin: the feet stand at y 0, toes show
    a = dino_biped(
        {"skin": skin, "belly": belly, "face": face, "shine": shine, "tail": tail},
        arm_pose={"left": (-22.0, 78.0), "right": (-22.0, 78.0)},
        **TREX_BODY,
    )
    body_shell(vest, belly, a)
    hard_hat(hat, hat_band, a)
    back_bumps(bumps, a)
    (lx, ly, lz), (rx, ry, rz) = a["hands"]["left"], a["hands"]["right"]
    clipboard(board, paper, ((lx + rx) / 2, (ly + ry) / 2 + 0.2, min(lz, rz) - 0.3), tilt=-22.0)
    # Control podium at local +X: stepped stone pedestal, angled top, lever, gauge.
    px = 4.1
    block(podium, (px, 0.95, 0.2), (2.2, 1.5, 1.8), bevel=0.2)
    block(podium, (px, 2.3, 0.2), (1.8, 1.2, 1.5), bevel=0.2)
    block(podium, (px, 3.05, 0.1), (2.1, 0.3, 1.8), bevel=0.08, rot=rot_x(-18))
    bar(lever, (px + 0.55, 3.15, 0.3), (px + 0.55, 4.6, -0.2), 0.16)
    ellipsoid(knob, (px + 0.55, 4.72, -0.24), (0.32, 0.32, 0.32), rings=4, segments=6)
    oriented_ellipsoid(gauge, (px - 0.35, 3.3, -0.12), (0.45, 0.45, 0.05), normal=(0, 0.31, -0.95), rings=3, segments=10)
    bar(knob, (px - 0.35, 3.33, -0.2), (px - 0.13, 3.55, -0.27), 0.06)
    rig_split(
        m,
        dino_bones(a),
        static=("Mat", "Podium", "Lever", "LeverKnob", "GaugeFace"),
        # Face / shine / hat ride the head; vest, bumps and tail the torso; the clipboard the right arm.
        assign={
            "Tail": "Torso", "Vest": "Torso", "Bumps": "Torso", "Face": "Head", "Shine": "Head", "Hat": "Head",
            "HatBand": "Head", "Clipboard": "ArmR", "ClipPaper": "ArmR",
        },
    )
    return m


TREX_SCALE = 3.2
PILLAR_H = 6.0
PLINTH_H = 1.0


def build_golden_trex():
    """
    FINALE — the Golden T-Rex Statue: a basalt pillar with gold bands rising from the crater islet, a
    gold plinth, and on it a giant golden T. rex (W6's shared dino_biped at 3.2x, all gold, light-gold
    belly) roaring happily at the sky with both tiny arms up, tail raised behind, wearing a little
    golden crown with amber gems. Glow-budget safe: no big Neon (gold studs + Smooth gems only).
    """
    m = Model(
        "D6_GoldenTRex",
        f"islet top centre in the crater (layout: VOLCANO * (0, {ISLET_TOP}, 0)); faces -Z; statue feet at y {PILLAR_H + PLINTH_H}",
        budget=6000,
    )
    pillar = m.piece("Pillar", ROCK_DARK)
    bands = m.piece("PillarBands", GOLD_DARK, material="StudsSmall")
    plinth = m.piece("Plinth", GOLD_DARK)
    gold = m.piece("Gold", GOLD)
    light = m.piece("GoldLight", GOLD_LIGHT)
    dark = m.piece("Eyes", EYE, material="Smooth")
    shine = m.piece("Shine", SHINE, material="Smooth")
    gems = m.piece("Gems", AMBER, material="Smooth")
    cylinder(pillar, (0, -0.05, 0), (0, PILLAR_H, 0), 2.7, segments=10, radius_b=2.4)
    for y in (1.6, 4.0):
        revolve(bands, [(2.45, y), (2.95, y), (2.95, y + 0.7), (2.45, y + 0.7)], segments=10, closed=True)
    revolve(plinth, [(0.0, PILLAR_H - 0.1), (4.6, PILLAR_H - 0.1), (5.0, PILLAR_H + 0.35), (5.0, PILLAR_H + PLINTH_H), (0.0, PILLAR_H + PLINTH_H)], segments=16)
    feet = PILLAR_H + PLINTH_H

    def statue():
        # Both tiny arms up in a happy cheer; drawn at the origin, then scaled onto the plinth.
        return dino_biped(
            {"skin": gold, "belly": light, "face": dark, "shine": shine, "tail": gold},
            arm_pose={"left": (65.0, 165.0), "right": (65.0, 165.0)},
            **TREX_BODY,
        )

    a = place_new([gold, light, dark, shine], statue, Xf((0.0, feet, 0.4)), TREX_SCALE)
    hc, hr = biped_geometry(a)["head"]
    head = Vector(hc) * TREX_SCALE + Vector((0.0, feet, 0.4))
    top = a["head_top"] * TREX_SCALE + feet
    toy_crown(gold, gems, (head.x, top - 0.55, head.z + 0.2), 1.6, 1.9, points=5, segments=16)
    return m


BUILDERS = {
    "D6_Floor": build_floor,
    "D6_EntryArch": build_entry_arch,
    "D6_VolcanoBase": build_volcano_base,
    "D6_VolcanoTop": build_volcano_top,
    "D6_LavaChannel": build_lava_channel,
    "D6_StoneTurbines": build_stone_turbine,
    "D6_SteamVents": build_steam_vents,
    "D6_MagmaPumps": build_magma_pump,
    "D6_CrystalCore": build_crystal_core,
    "D6_LavaFalls": build_lava_falls,
    "D6_SkyBridge": build_sky_bridge,
    "D6_ObsidianCrown": build_obsidian_crown,
    "D6_ChiefTyra": build_chief_tyra,
    "D6_GoldenTRex": build_golden_trex,
}
