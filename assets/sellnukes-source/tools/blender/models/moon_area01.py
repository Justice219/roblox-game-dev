"""
moon_area01.py — Moon Base area M1 "Crater Camp" models (W6 art-d12, owner R70) + the shared Moon
Base art helpers used by every moon_areaNN.py builder (spec 2026-10-31-r69-moon-lucky-juice-design
§2.2 "Look": pale lilac / moon-grey stud ground with craters, chrome-white + candy accents — mint,
coral, sunshine yellow, violet — round friendly shapes; NOT Nuke Town's grey-metal hazard look).

A friendly little space capsule has landed against a crater wall; next to it a workbench under a big
arc lamp is where Bleep Bot (a round robot) assembles moon-rock nukes.

    M1_Floor        moon-dust lot: craters (raised rims + darker bowls), a light dust path       base
    M1_EntryArch    "CRATER CAMP" arch: chrome capsule posts, ringed-planet finials, star bulbs  base
    M1_CraterWall   the crater rim across the back with the landed capsule (<= 6k)              base
    M1_RockCluster  a small cluster of moon rocks + violet crystals (placed many times, any area)  base
    M1_CapsuleBench the producer: a chrome workbench on fuel-tank legs, a moon-rock nuke in its   M1_CapsuleBench
                    cradle (hovers: `Nuke*` pieces bob as one) and a big arc lamp over it
    M1_CraterLamps  a round globe lamp post (placed 4x)                                           M1_CraterLamps
    M1_MoonTools    chrome pegboard rack of candy space tools + a toolbox                         M1_MoonTools
    M1_FlagPole     flag pole with the SELL NUKES logo flag (no country), both faces (R17)        M1_FlagPole
    M1_SolarPanels  one solar panel on a stand; the `Solar*` pieces tilt as one (placed 3x)       M1_SolarPanels
    M1_AirPump      a round air tank with a gauge, a hose and a hand pump                         M1_AirPump
    M1_BleepBot     the Manager: a round chrome robot with a mint screen face, antenna star and a M1_BleepBot
                    coral tool belt; split into the R30 rig groups
    M1_CraterRail   16-stud chrome railing run with candy rails (placed 4x)                       M1_CraterRail

Placement: src/shared/Config/Worlds/Moon/Layouts/Area01.luau (slot-local frame, docs/areas-art.md).
SLOT-ORIGIN models (M1_Floor, M1_CraterWall) use the slot origin as pivot (identity cf): road-side
edge midpoint at ground level, +Z away from the road, slot x in [-52, 52], z in [0, 70]. Every
other model is pivoted at its own ground centre with its front toward -Z (the road).

WorldFx piece names (rows in WorldFxConfig "-- Moon Base M1/M2" block):
    Solar*   M1 solar panel + its cell bars + frame: one group, tilts about the axle (`Solar` row)
    Bulb*    lamp globes / star bulbs: existing soft light row
    Nuke*    the bench's moon-rock nuke hovers as ONE group (existing `Nuke` bob row, R25)
Manager rig (R30): M1_BleepBot pieces are Torso* / Head* / ArmL* / ArmR* / LegL* / LegR*.

Shared helpers exported for moon_area02..06.py (import from models.moon_area01):
    palette constants (MOON_GROUND, MOON_DARK, MOON_DUST, CHROME, CHROME_SHADE, MINT_C, CORAL_C,
    SUNNY, VIOLET, NAVY, ROCK_LILAC, ROCK_DEEP, CRYSTAL_GLOW, STAR_GLOW, ALIEN_GREEN, INK_M)
    crater(rim, bowl, center, radius)            raised crater rim + darker bowl on a floor
    moon_rock(piece, center, radii, seed)        lumpy lilac rock (wraps dino boulder)
    crystal_cluster(body, glow, center, seed)    violet crystals with one small glowing tip
    moon_nuke(body, band, fins, base, height)    the Moon product: a round moon-rock nuke
    moon_arch(key, lines, ...)                   capsule-post entry arch, double-sided letters (R17)
    toon_biped(parts, ...) / toon_bones(anchors) chunky cartoon biped (robot or alien) + R30 skeleton
    rail_run(key, ...)                           16-stud railing run builder

Budgets (docs/world-art.md §4; spec §15: a fully built area <= 28k triangles): lots <= 2,000,
backdrop <= 6,000, arches <= 4,500, machines / managers <= 3,000, small props <= 1,500.
Z-fight layers (docs/areas-art.md R18): lot top y = 0.5 (LOT_TOP), dust path +0.06, crater bowls
+0.1, decals +0.18; every trim / band is proud of what it wraps.
"""

from __future__ import annotations

import math

from mathutils import Vector

from models._critter_kit import eyes, oriented_ellipsoid, plate, smile, star, tube
from models.area01 import LOT_TOP, SLOT_PIVOT, block_text, sign_text, text_cells
from models.area04 import _hash
from models.dino_area01 import boulder
from snkit.core import Model
from snkit.kit import block, disc, trefoil
from snkit.shapes import cylinder, ellipsoid, extrude_outline, loft, prism, revolve, ring_tube, rot_x, rot_y, rot_z

# ------------------------------------------------------------------------------------------------
# Moon Base palette (spec §2.2 "Look"). RGB 0..255; the stud map darkens these ~10 % on screen.
# ------------------------------------------------------------------------------------------------

MOON_GROUND = (204, 198, 226)  # pale lilac moon dust (lot)
MOON_DARK = (166, 158, 196)  # crater bowls
MOON_DUST = (232, 228, 244)  # paths
CHROME = (238, 242, 250)  # chrome-white shells
CHROME_SHADE = (198, 206, 226)  # second chrome tone (rims, joints)
MINT_C = (110, 226, 180)
CORAL_C = (255, 124, 108)
SUNNY = (255, 214, 60)
VIOLET = (156, 104, 236)
NAVY = (44, 56, 120)
ROCK_LILAC = (170, 162, 198)  # moon rocks
ROCK_DEEP = (132, 124, 168)
CRYSTAL_GLOW = (200, 160, 255)  # small Neon crystal tips (R19)
STAR_GLOW = (255, 236, 140)  # small Neon star bulbs (R19)
ALIEN_GREEN = (140, 230, 120)
INK_M = (40, 36, 60)  # eyes, smiles

SLOT_W = 104.0
SLOT_D = 70.0


# ------------------------------------------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------------------------------------------


def moon_rock(piece, center, radii, seed=0, rings=4, segments=7):
    """
    Lumpy lilac moon rock (the deterministic Dino `boulder`, a touch smoother). Centre it at
    ground + 0.72 * radius_y so it never sinks more than 0.2 into the lot (R24).

    Example: moon_rock(rock, (4, LOT_TOP + 0.9, 12), (1.6, 1.2, 1.4), seed=7)
    """
    boulder(piece, center, radii, seed=seed, rings=rings, segments=segments, lump=0.12)


def crater(rim, bowl, center, radius, rim_h=0.42, rim_w=None, segments=14):
    """
    Cartoon crater sitting ON a floor whose top is center.y: a raised round rim (a revolved bump,
    `rim` piece) and a darker bowl disc inside it (`bowl` piece, top +0.1 above the floor, tucked
    under the rim's inner slope so no top plane is shared, R18). ~6 * segments + 2 * segments tris.

    Example: crater(rims, bowls, (10, LOT_TOP, 30), 3.0)
    """
    cx, cy, cz = center
    w = rim_w if rim_w is not None else max(0.6, radius * 0.32)
    r0 = radius
    revolve(
        rim,
        [(r0 - 0.05, 0.0), (r0 + w * 0.25, rim_h), (r0 + w * 0.55, rim_h * 0.9), (r0 + w, 0.0)],
        center=(cx, cy - 0.02, cz),
        segments=segments,
        closed=True,
    )
    disc(bowl, (cx, cy - 0.04, cz), r0 + w * 0.1, 0.14, segments=segments, bevel=0.03)


def crystal_cluster(body, glow, center, scale=1.0, seed=0, count=4):
    """
    Violet crystal cluster: hexagonal crystals fanning out of `center` (roots 0.3 below it so they
    never float) in the `body` piece, plus ONE small crystal in `glow` (a tiny Neon accent, R19).
    """
    cx, cy, cz = center
    for i in range(count + 1):
        a = 2 * math.pi * i / max(count, 1) + _hash(seed, i)
        tilt = 0.0 if i == 0 else 24.0 + 12.0 * _hash(seed + 3, i)
        h = scale * (2.2 if i == 0 else 1.1 + 0.8 * _hash(seed + 5, i))
        r = scale * (0.42 if i == 0 else 0.26 + 0.1 * _hash(seed + 7, i))
        piece = glow if i == count else body
        if piece is glow:
            h, r = scale * 0.9, scale * 0.18
        off = 0.0 if i == 0 else scale * 0.45
        base = (cx + off * math.cos(a), cy - 0.3, cz + off * math.sin(a))
        rot = rot_y(-math.degrees(a)) @ rot_z(-tilt)
        revolve(piece, [(0.0, 0.0), (r, 0.0), (r, h * 0.7), (0.0, h)], center=base, segments=6, rot=rot)


def moon_nuke(body, band, fins, base, height=2.6, segments=10):
    """
    The Moon product: a round moon-rock nuke — a lilac speckled egg body, a chrome nose, three round
    candy fins and a glowing band (`band` = small Neon piece; its box stays under the R19 limit for
    heights <= ~3). Standing on `base` (bottom centre). Returns the band centre y.
    """
    bx, by, bz = base
    r = height * 0.32
    body_h = height * 0.72
    cy = by + body_h * 0.5 + 0.05
    ellipsoid(body, (bx, cy, bz), (r, body_h * 0.5, r), rings=6, segments=segments)
    revolve(fins, [(r * 0.5, 0.0), (r * 0.32, height * 0.13), (r * 0.1, height * 0.22), (0.0, height * 0.25)], center=(bx, by + body_h * 0.84, bz), segments=segments)
    for i in range(3):
        a = math.radians(-90 + 120 * i)
        c = (bx + math.cos(a) * r * 0.92, by + body_h * 0.18, bz + math.sin(a) * r * 0.92)
        oriented_ellipsoid(fins, c, (r * 0.42, body_h * 0.22, 0.12), normal=(-math.sin(a), 0.0, math.cos(a)), rings=4, segments=8)
    band_y = cy + body_h * 0.05
    revolve(band, [(r * 1.03, -height * 0.05), (r * 1.06, 0.0), (r * 1.03, height * 0.05)], center=(bx, band_y, bz), segments=segments, closed=True)
    return band_y


def moon_arch(
    key,
    lines,
    *,
    inner=14.0,
    post_h=9.0,
    post_r=1.6,
    shell=CHROME,
    band_a=CORAL_C,
    band_b=MINT_C,
    board=NAVY,
    frame=CHROME_SHADE,
    letters=SUNNY,
    planet=VIOLET,
    ring=MINT_C,
    cell=None,
    budget=4500,
):
    """
    Moon Base entry arch: two chrome capsule posts (rounded cylinders with candy bands and round
    portholes), a navy board in a rounded chrome frame carrying the area name in block letters on
    BOTH faces (owner R17), a ringed-planet finial above each post, a sunshine crescent moon crest and
    small Neon star bulbs at the board corners (R19). Mirrored left/right and front/back.

    inner: clear width between the posts. Pivot: ground centre under the board, sign faces -Z.
    Returns the Model with `arch_info` (board_y, board_h, board_w, post_x, top_y).

    Example: moon_arch("M2_EntryArch", ["COSMIC", "DINER"], board=VIOLET)
    """
    m = Model(key, "ground centre between the posts; sign faces -Z (the road), reads from both sides", budget=budget)
    posts = m.piece("Posts", shell)
    bands_a = m.piece("BandsA", band_a)
    bands_b = m.piece("BandsB", band_b)
    ports = m.piece("Portholes", NAVY, material="Smooth")
    panel = m.piece("Panel", board)
    trim = m.piece("Frame", frame)
    text = m.piece("Letters", letters, material="Smooth")
    planets = m.piece("Planets", planet)
    rings = m.piece("PlanetRings", ring)
    crest = m.piece("Crest", SUNNY, material="StudsSmall")
    px = inner / 2 + post_r + 0.4
    for sx in (-1, 1):
        x = sx * px
        # Capsule post: plinth, rounded body (revolve), two proud candy bands, two portholes.
        revolve(posts, [(0.0, 0.0), (post_r + 0.6, 0.0), (post_r + 0.6, 0.7), (post_r, 0.9), (post_r, post_h - 0.6), (post_r * 0.6, post_h), (0.0, post_h + 0.05)], center=(x, 0.0, 0.0), segments=14)
        for y, piece in ((2.2, bands_a), (post_h - 2.2, bands_b)):
            cylinder(piece, (x, y - 0.3, 0.0), (x, y + 0.3, 0.0), post_r + 0.08, segments=14)
        for sz in (-1, 1):
            oriented_ellipsoid(ports, (x, post_h * 0.5, sz * (post_r + 0.01)), (0.55, 0.55, 0.12), normal=(0, 0, sz), rings=4, segments=10)
            ring_tube(trim, (x, post_h * 0.5, sz * (post_r + 0.08)), 0.6, 0.16, 0.14, segments=12, axis="Z")
    lines = [lines] if isinstance(lines, str) else list(lines)
    board_w = inner + 2 * (post_r + 0.4) * 2 + 1.0
    widest = max(text_cells(line) for line in lines)
    pad = 0.9
    if cell is None:
        cell = min(0.6, (board_w - 2 * pad - 1.2) / widest)
    rows = len(lines) * 7 + (len(lines) - 1) * 2
    board_h = rows * cell + 2 * pad
    board_y = post_h + 0.45 + board_h / 2
    depth = 1.0
    block(panel, (0, board_y, 0), (board_w - 0.5, board_h - 0.5, depth), bevel=0.12)
    # Rounded tube frame proud of the panel (top / bottom run past the ends, sides between them).
    tr = 0.38
    for sy in (-1, 1):
        y = board_y + sy * (board_h / 2)
        cylinder(trim, (-board_w / 2 - 0.4, y, 0), (board_w / 2 + 0.4, y, 0), tr, segments=10)
    for sx in (-1, 1):
        x = sx * (board_w / 2)
        cylinder(trim, (x, board_y - board_h / 2 + tr * 0.7, 0), (x, board_y + board_h / 2 - tr * 0.7, 0), tr * 0.9, segments=10)
    sign_text(text, lines, (0, board_y, 0), cell, 0.3, depth / 2)
    top_y = board_y + board_h / 2 + tr
    # Crest: a fat sunshine crescent moon ("C", horns toward +X) standing on the top tube, extruded
    # along Z so it reads from both sides. Outer arc r 1.5 round the left, inner arc r 1.15 offset
    # +0.55 in x back again.
    outline = []
    steps = 12
    cy = top_y + 1.55
    for i in range(steps + 1):
        a = math.radians(45 + 270 * i / steps)
        outline.append((1.5 * math.cos(a), cy + 1.5 * math.sin(a)))
    for i in range(steps, -1, -1):
        a = math.radians(58 + 244 * i / steps)
        outline.append((0.55 + 1.15 * math.cos(a), cy + 1.15 * math.sin(a)))
    prism(crest, [(x, y, 0.0) for x, y in outline], (0, 0, 1), 0.5)
    # Ringed-planet finials standing on the board's top tube above each post (the board spans the
    # posts, so a finial on the post cap would sit inside the board).
    for sx in (-1, 1):
        c = (sx * px, top_y + 0.95, 0.0)
        ellipsoid(planets, c, (1.0, 1.0, 1.0), rings=7, segments=12)
        ring_tube(rings, c, 1.55, 0.42, 0.12, segments=16, axis="Y")
    # Star bulbs at the four board corners, both faces; one small Neon piece per side (R19).
    for sx, side in ((-1, "L"), (1, "R")):
        bulb = m.piece(f"Bulb{side}", STAR_GLOW, material="Neon")
        for sy in (-1, 1):
            for sz in (-1, 1):
                star(bulb, (sx * (board_w / 2 - 0.9), board_y + sy * (board_h / 2 - 0.85), sz * (depth / 2 + 0.06)), 0.34, 0.1, normal=(0, 0, sz))
    m.arch_info = {"board_y": board_y, "board_h": board_h, "board_w": board_w, "post_x": px, "top_y": top_y}
    return m


def toon_biped(parts, *, body=(1.3, 1.25, 1.15), head=(1.1, 1.0, 1.0), head_shape="round", leg_h=1.3, arm_pose=None, feet="boots"):
    """
    Chunky cartoon biped (robots and aliens, ~6 studs tall) standing at the origin, facing -Z: a
    round body, a big head (head_shape "round" = sphere, "dome" = a rounded robot head), short legs
    with round boots (or `feet="skates"`: roller skates with four wheels), two-segment arms with
    round mitts. No face is drawn: callers add eyes / screens / antennae (anchors below).

    parts: role -> piece: "body", "head", "limbs" (arms + legs), "hands", "feet"; optional "wheels"
           (skates). The same piece may serve several roles.
    arm_pose: {"left": (outward deg, forward deg), "right": (...)}; default relaxed.
    Returns anchors: hip, neck, head (centre), head_r, head_top, head_front_z, chest (front),
    hands, shoulder_x/y/z, leg_x, body_c, body.
    """
    bw, bh, bd = body
    limbs, feet_p = parts["limbs"], parts["feet"]
    hip = leg_h + 0.3
    leg_x = bw * 0.45
    for sx in (-1, 1):
        x = sx * leg_x
        cylinder(limbs, (x, 0.45, 0.0), (x, hip + 0.2, 0.0), 0.34, segments=8)
        if feet == "skates":
            # Roller skate: a rounded boot on a plate with four wheels (the wheels piece).
            block(feet_p, (x, 0.62, -0.15), (0.8, 0.62, 1.2), bevel=0.22)
            block(feet_p, (x, 0.28, -0.12), (0.7, 0.12, 1.45), bevel=0.04)
            wheels = parts.get("wheels", feet_p)
            for wz in (-0.6, 0.38):
                cylinder(wheels, (x - 0.32, 0.13, wz - 0.12), (x + 0.32, 0.13, wz - 0.12), 0.13, segments=8)
        else:
            ellipsoid(feet_p, (x, 0.32, -0.18), (0.5, 0.34, 0.68), rings=5, segments=8)
    body_c = (0.0, hip + bh * 0.82, 0.0)
    ellipsoid(parts["body"], body_c, body, rings=8, segments=14)
    neck = body_c[1] + bh * 0.86
    hw, hh, hd = head
    head_c = (0.0, neck + hh * 0.92, -0.05)
    if head_shape == "dome":
        # Rounded robot head: a fat rounded box (revolve-free, crisp silhouette).
        block(parts["head"], head_c, (hw * 2, hh * 1.8, hd * 1.9), bevel=min(hw, hh) * 0.45, segments=3)
    else:
        ellipsoid(parts["head"], head_c, head, rings=8, segments=14)
    pose = {"left": (10.0, 30.0), "right": (10.0, 30.0)}
    if arm_pose:
        pose.update(arm_pose)
    shoulder_y = body_c[1] + bh * 0.4
    shoulder_x = bw * 0.86
    shoulder_z = 0.0
    hands = {}
    for side, (out, fwd) in pose.items():
        sx = -1 if side == "left" else 1
        shoulder = Vector((sx * shoulder_x, shoulder_y, shoulder_z))
        d = rot_z(sx * out) @ rot_x(fwd) @ Vector((0.0, -1.0, 0.0))
        elbow = shoulder + d * 0.75
        hand = elbow + d * 0.7
        cylinder(limbs, tuple(shoulder), tuple(elbow), 0.26, segments=7)
        cylinder(limbs, tuple(elbow), tuple(hand), 0.23, segments=7)
        ellipsoid(parts["hands"], tuple(hand), (0.32, 0.32, 0.32), rings=5, segments=8)
        hands[side] = tuple(hand)
    return {
        "hip": hip,
        "neck": neck,
        "head": head_c,
        "head_r": head,
        "head_top": head_c[1] + (hh * 0.9 if head_shape == "dome" else hh),
        "head_front_z": head_c[2] - (hd * 0.95 if head_shape == "dome" else hd),
        "chest": (0.0, shoulder_y - 0.25, body_c[2] - bd * 0.92),
        "hands": hands,
        "shoulder_x": shoulder_x,
        "shoulder_y": shoulder_y,
        "shoulder_z": shoulder_z,
        "leg_x": leg_x,
        "body_c": body_c,
        "body": body,
    }


def toon_bones(a) -> dict:
    """
    R30 skeleton of `toon_biped` (for models._npc_rig.rig_split). Joint = the first point of each
    segment: hip centre (Torso), neck (Head), shoulders (ArmL / ArmR), hip sockets (LegL / LegR).
    The torso bone stops below the neck so the head classifies as Head.
    """
    hip, neck = a["hip"], a["neck"]
    sx, sy, sz = a["shoulder_x"], a["shoulder_y"], a["shoulder_z"]
    lx = a["leg_x"]
    return {
        "Torso": ((0.0, hip, 0.0), (0.0, neck - 0.25, 0.0)),
        "Head": ((0.0, neck, 0.0), (0.0, a["head_top"], -0.05)),
        "ArmL": ((-sx, sy, sz), a["hands"]["left"]),
        "ArmR": ((sx, sy, sz), a["hands"]["right"]),
        "LegL": ((-lx, hip, 0.0), (-lx, 0.0, -0.1)),
        "LegR": ((lx, hip, 0.0), (lx, 0.0, -0.1)),
    }


def rail_run(key, rail_a, rail_b, budget=600, posts_color=CHROME):
    """
    16-stud railing run (pivot = ground centre, runs along X, front -Z): three chrome posts with
    ball caps and two candy tube rails (rail_a top, rail_b bottom) passing in front of the posts.
    """
    m = Model(key, "ground centre of the run; runs along X (16 long)", budget=budget)
    posts = m.piece("Posts", posts_color)
    caps = m.piece("Caps", CHROME_SHADE)
    top = m.piece("RailTop", rail_a)
    low = m.piece("RailLow", rail_b)
    for x in (-7.5, 0.0, 7.5):
        cylinder(posts, (x, 0.0, 0.0), (x, 2.9, 0.0), 0.3, segments=8)
        ellipsoid(caps, (x, 3.05, 0.0), (0.42, 0.42, 0.42), rings=4, segments=8)
    cylinder(top, (-7.9, 2.4, -0.42), (7.9, 2.4, -0.42), 0.2, segments=8)
    cylinder(low, (-7.9, 1.2, -0.42), (7.9, 1.2, -0.42), 0.17, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# M1 base: floor, arch, crater wall, rock cluster
# ------------------------------------------------------------------------------------------------

BENCH_Z = 40.0  # bench pivot z (slot)
CLEARING_R = 11.0
WALL_FRONT = 54.0  # crater wall foot line (front) z
CAPSULE_X, CAPSULE_Z = -24.0, 52.5  # the landed capsule (crater wall model), in front of the ridge


def _path_outline():
    """Dust path from the arch (z 0) widening to a round clearing in front of the bench (x, z)."""
    pts = [(-4.5, 0.0), (-5.5, 14.0), (-6.5, BENCH_Z - CLEARING_R + 1.5)]
    steps = 16
    for i in range(steps + 1):
        a = math.radians(142 + 256 * i / steps)
        pts.append((CLEARING_R * math.cos(a), BENCH_Z - CLEARING_R * math.sin(a)))
    pts += [(6.5, BENCH_Z - CLEARING_R + 1.5), (5.5, 14.0), (4.5, 0.0)]
    return pts


# Floor craters (x, z, radius): clear of the path, the pad strip (z < 16) and every build footprint.
FLOOR_CRATERS = ((-30.0, 24.0, 3.2), (-41.0, 40.0, 2.6), (29.0, 22.0, 2.8), (40.0, 38.0, 3.4), (17.0, 49.0, 2.0), (-44.0, 24.0, 1.6))


def build_floor():
    """Moon-dust lot: one ground plate, the dust path + clearing (+0.06) and raised-rim craters."""
    m = Model("M1_Floor", SLOT_PIVOT, budget=2000)
    ground = m.piece("Ground", MOON_GROUND, material="StudsLarge")
    path = m.piece("Path", MOON_DUST)
    rims = m.piece("CraterRims", (186, 180, 214))
    bowls = m.piece("CraterBowls", MOON_DARK)
    block(ground, (0, LOT_TOP / 2, SLOT_D / 2), (SLOT_W, LOT_TOP, SLOT_D), bevel=0.1)
    extrude_outline(path, _path_outline(), LOT_TOP - 0.04, LOT_TOP + 0.06)
    for x, z, r in FLOOR_CRATERS:
        crater(rims, bowls, (x, LOT_TOP, z), r, segments=12)
    return m


def build_arch():
    """CRATER CAMP arch: chrome capsule posts, navy board, sunshine letters, planet finials."""
    return moon_arch("M1_EntryArch", ["CRATER", "CAMP"])


def build_crater_wall():
    """
    The crater rim across the back of the lot (slot pivot): one long smooth lilac bank (a loft from
    the foot line z 54 up to a 7-9 stud crest at z ~64, gently waving along x), a row of big rounded
    rocks along its crest (the rim reaches 12-15), small craters on its slope, violet crystal
    clusters, and the landed capsule leaning back against the bank at x -24: a chrome cone with a
    coral band, navy portholes, a mint nose, three landing legs and a striped parachute draped over
    the rim behind it. Lower than the Dino cliff so the starry sky shows. <= 6,000 triangles.
    """
    m = Model("M1_CraterWall", SLOT_PIVOT + "; crater wall foot z = 54; capsule at x -24, z 52.5", budget=6000)
    bank = m.piece("Bank", (186, 178, 212))
    rock = m.piece("Rock", ROCK_LILAC)
    deep = m.piece("RockDeep", ROCK_DEEP)
    rims = m.piece("FaceCraters", (206, 200, 230))
    bowls = m.piece("FaceBowls", ROCK_DEEP)
    body = m.piece("Crystals", VIOLET)
    glow = m.piece("CrystalTips", CRYSTAL_GLOW, material="Neon")
    shell = m.piece("CapsuleShell", CHROME)
    band = m.piece("CapsuleBand", CORAL_C)
    nose = m.piece("CapsuleNose", MINT_C)
    port = m.piece("CapsulePorts", NAVY, material="Smooth")
    legs = m.piece("CapsuleLegs", CHROME_SHADE)
    chute = m.piece("Parachute", (255, 244, 236))
    chute_b = m.piece("ParachuteStripes", CORAL_C)

    def crest(x: float) -> float:
        """Crest height of the bank at slot x (smooth wave, 7..9.5)."""
        return 8.2 + 0.9 * math.sin(x * 0.11) + 0.5 * math.sin(x * 0.27 + 1.3)

    # Bank: cross-sections every 5.2 studs along x; profile (z, y) from the foot over the crest
    # down to the slot back edge. Ends are capped at the slot edges (x +-52).
    sections = []
    xs = [-52.0 + 104.0 * i / 20 for i in range(21)]
    for x in xs:
        c = crest(x)
        profile = [(WALL_FRONT, LOT_TOP), (WALL_FRONT + 3.0, LOT_TOP + c * 0.42), (WALL_FRONT + 6.0, LOT_TOP + c * 0.8), (WALL_FRONT + 9.5, LOT_TOP + c), (SLOT_D - 0.2, LOT_TOP + c * 0.86), (SLOT_D - 0.2, LOT_TOP)]
        sections.append([(x, y, z) for z, y in profile])
    loft(bank, sections)
    # Rocks along the crest (heights hashed so neighbours differ), skipping the capsule's notch.
    k = 0
    x = -50.0
    while x < 50.0:
        w = 8.0 + 4.0 * _hash(k, 11)
        cx = min(x + w / 2, 49.0)
        h = 3.5 + 3.5 * _hash(k, 13)
        moon_rock(rock if k % 2 else deep, (cx, LOT_TOP + crest(cx) - 0.3 + h * 0.45, WALL_FRONT + 10.5 + 1.5 * _hash(k, 19)), (w * 0.62, h * 0.75, 3.6), seed=300 + k, rings=5, segments=9)
        x += w * 0.85
        k += 1
    # A low front lip of smaller rocks along the foot (breaks the straight foot line).
    for i, x in enumerate((-47.0, -38.5, -12.0, -3.0, 6.0, 15.0, 30.0, 39.0, 47.0)):
        r = 1.3 + 0.7 * _hash(i, 21)
        moon_rock(rock if i % 2 else deep, (x, LOT_TOP + r * 0.72, WALL_FRONT + 0.6), (r * 1.5, r, r * 1.1), seed=400 + i)
    # Small craters on the bank slope, tilted to lie on it (proud of the slope by ~0.1).
    slope = math.degrees(math.atan2(1.0, 7.14))  # ~ the mid-slope angle (rise / run)
    for i, x in enumerate((-38.0, -8.0, 12.0, 34.0)):
        c = crest(x)
        y = LOT_TOP + c * 0.61 + 0.12
        z = WALL_FRONT + 4.5
        r = 1.1 + 0.4 * _hash(i, 23)
        rot = rot_x(-(90.0 - slope * 0.0) + 40.0)
        revolve(rims, [(r - 0.05, 0.0), (r + 0.15, 0.32), (r + 0.5, 0.0)], center=(x, y, z), segments=10, closed=True, rot=rot)
        revolve(bowls, [(0.0, 0.03), (r + 0.05, 0.03), (r + 0.05, 0.12), (0.0, 0.12)], center=(x, y, z), segments=10, rot=rot)
    # Crystal clusters at the foot (one small glowing tip each).
    # Based 0.35 up so the clusters' 0.3-stud roots (tilted) end on the lot, not in it (R24).
    for i, x in enumerate((-30.0, 8.0, 24.0, 44.0)):
        crystal_cluster(body, glow, (x, LOT_TOP + 0.35, WALL_FRONT + 0.2), scale=0.9 + 0.3 * _hash(i, 31), seed=500 + i)
    # Landed capsule (1.4x): leaning back 14 degrees against the bank.
    lean = rot_x(-14)
    sc = 1.4
    base = Vector((CAPSULE_X, LOT_TOP + 1.4, CAPSULE_Z))

    def at(p):
        return tuple(base + lean @ (Vector(p) * sc))

    prof = [(0.0, 0.0), (3.4, 0.0), (3.6, 0.6), (2.6, 4.4), (1.2, 6.2), (0.0, 6.6)]
    revolve(shell, [(r * sc, y * sc) for r, y in prof], center=tuple(base), segments=16, rot=lean)
    revolve(band, [(3.48 * sc, 0.9 * sc), (3.62 * sc, 1.2 * sc), (3.45 * sc, 1.7 * sc)], center=tuple(base), segments=16, rot=lean, closed=True)
    revolve(nose, [(1.0 * sc, 6.2 * sc), (0.62 * sc, 7.1 * sc), (0.0, 7.4 * sc)], center=tuple(base), segments=12, rot=lean)
    for ang, y in ((-24.0, 3.0), (24.0, 3.0), (0.0, 4.8)):
        a = math.radians(ang)
        r_at = 3.6 - (3.6 - 2.6) * (y - 0.6) / 3.8 + 0.04
        p = (r_at * math.sin(a), y, -r_at * math.cos(a))
        n = lean @ Vector((math.sin(a), 0.26, -math.cos(a))).normalized()
        oriented_ellipsoid(port, at(p), (0.62 * sc, 0.62 * sc, 0.12), normal=tuple(n), rings=4, segments=10)
    for i in range(3):
        a = math.radians(-90 + 120 * i + 60)
        top = (3.0 * math.cos(a), 0.6, 3.0 * math.sin(a))
        foot = (4.2 * math.cos(a), -0.9, 4.2 * math.sin(a))
        # The lean can push a foot under the lot: clamp it onto the foot pad (R24).
        fx, fy, fz = at(foot)
        fy = max(fy, LOT_TOP + 0.15)
        cylinder(legs, at(top), (fx, fy, fz), 0.28, segments=6)
        disc(legs, (fx, LOT_TOP, fz), 0.75, 0.2, segments=8, bevel=0.05)
    # Parachute draped over the rim behind the capsule: a squashed dome with coral stripes.
    chute_c = (CAPSULE_X + 2.0, LOT_TOP + crest(CAPSULE_X) + 1.2, WALL_FRONT + 9.0)
    ellipsoid(chute, chute_c, (5.4, 1.7, 3.6), rings=5, segments=12)
    for i in range(3):
        a = math.radians(-50 + 50 * i)
        oriented_ellipsoid(chute_b, (chute_c[0] + 5.3 * math.sin(a) * 0.62, chute_c[1] + 1.3, chute_c[2] - 0.2), (0.7, 0.3, 3.0), normal=(0, 1, 0), up=(0, 0, 1), rings=3, segments=8)
    return m


def build_rock_cluster():
    """A small cluster of moon rocks with a violet crystal cluster (pivot = ground centre, ~5 wide)."""
    m = Model("M1_RockCluster", "ground centre of the cluster; any yaw", budget=700)
    rock = m.piece("Rock", ROCK_LILAC)
    deep = m.piece("RockDeep", ROCK_DEEP)
    body = m.piece("Crystals", VIOLET)
    glow = m.piece("CrystalTip", CRYSTAL_GLOW, material="Neon")
    moon_rock(rock, (0.0, 1.0, 0.0), (1.8, 1.4, 1.6), seed=610)
    moon_rock(deep, (1.9, 0.62, -0.8), (1.0, 0.85, 0.95), seed=611)
    moon_rock(rock, (-1.7, 0.45, 0.9), (0.8, 0.62, 0.7), seed=612)
    crystal_cluster(body, glow, (-1.2, 0.3, -1.2), scale=0.75, seed=613, count=3)
    return m


# ------------------------------------------------------------------------------------------------
# M1 builds
# ------------------------------------------------------------------------------------------------

BENCH_TOP = 3.4  # workbench top above the bench pivot


def build_capsule_bench():
    """
    The Crater Camp producer: a chrome workbench whose two legs are fat candy fuel tanks, a mint
    cradle holding a moon-rock nuke that hovers 0.45 above it (`Nuke*` pieces bob as one, R25), a
    space wrench and a drill-beam tool on the top, and a big arc lamp curving over from behind
    (globe = small Neon `BulbLamp`, soft light). Front (-Z) faces the customers.
    """
    m = Model("M1_CapsuleBench", "ground centre of the bench; customers on -Z; top y = 3.4", budget=3000)
    top = m.piece("Top", CHROME)
    trim = m.piece("Trim", CHROME_SHADE)
    tanks = m.piece("Tanks", CORAL_C)
    tank_bands = m.piece("TankBands", SUNNY)
    cradle = m.piece("Cradle", MINT_C)
    nuke = m.piece("NukeRock", (196, 186, 226), material="StudsSmall")
    fins = m.piece("NukeFins", CHROME, material="StudsSmall")
    band = m.piece("NukeBand", (140, 255, 210), material="Neon")
    tools = m.piece("Tools", VIOLET, material="StudsSmall")
    lamp = m.piece("ArcPost", NAVY)
    shade = m.piece("ArcShade", SUNNY)
    bulb = m.piece("BulbLamp", STAR_GLOW, material="Neon")
    # Fuel-tank legs: two upright rounded candy tanks with proud sunny bands under the top.
    for sx in (-1, 1):
        x = sx * 3.3
        revolve(tanks, [(0.0, 0.0), (1.0, 0.0), (1.2, 0.3), (1.2, 2.4), (1.0, 2.75), (0.0, 2.8)], center=(x, 0.0, 0.0), segments=12)
        for y in (0.8, 1.9):
            cylinder(tank_bands, (x, y - 0.14, 0.0), (x, y + 0.14, 0.0), 1.27, segments=12)
    # Chrome top slab + a proud rounded edge trim along the front.
    block(top, (0, BENCH_TOP - 0.4, 0), (10.0, 0.8, 3.8), bevel=0.3, segments=2)
    cylinder(trim, (-5.1, BENCH_TOP - 0.45, -1.95), (5.1, BENCH_TOP - 0.45, -1.95), 0.32, segments=8)
    # Cradle + hovering moon-rock nuke.
    revolve(cradle, [(0.0, 0.0), (1.2, 0.0), (1.3, 0.25), (1.05, 0.4), (0.0, 0.35)], center=(0, BENCH_TOP, 0.2), segments=12)
    moon_nuke(nuke, band, fins, (0, BENCH_TOP + 0.4 + 0.45, 0.2), height=2.8)
    # Space wrench + drill-beam tool lying on the top (right side).
    cylinder(tools, (2.0, BENCH_TOP + 0.15, -0.7), (3.8, BENCH_TOP + 0.15, -1.0), 0.14, segments=6)
    ring_tube(tools, (4.0, BENCH_TOP + 0.15, -1.03), 0.35, 0.18, 0.18, segments=8, axis="Y")
    cylinder(tools, (2.2, BENCH_TOP + 0.3, 0.8), (3.6, BENCH_TOP + 0.3, 0.8), 0.28, segments=8)
    cylinder(tools, (3.6, BENCH_TOP + 0.3, 0.8), (4.2, BENCH_TOP + 0.3, 0.8), 0.28, segments=8, radius_b=0.08)
    # Big arc lamp: a post behind the bench (+Z), an arc over the top, a shade + globe at the end.
    pts = [(-4.6, 0.0, 2.4), (-4.6, 6.0, 2.4), (-4.3, 8.2, 2.2), (-3.0, 9.4, 1.4), (-1.2, 9.6, 0.5)]
    tube(lamp, pts, 0.22, sides=8)
    disc(lamp, (-4.6, 0.0, 2.4), 0.8, 0.25, segments=10, bevel=0.06)
    revolve(shade, [(0.25, 0.4), (0.7, 0.3), (1.25, -0.35), (1.35, -0.55)], center=(-0.9, 9.4, 0.4), segments=12)
    ellipsoid(bulb, (-0.9, 8.75, 0.4), (0.5, 0.42, 0.5), rings=5, segments=10)
    return m


def build_crater_lamps():
    """A round globe lamp post (pivot = ground centre): chrome post, mint bands, glowing globe."""
    m = Model("M1_CraterLamps", "ground centre of one lamp post", budget=500)
    post = m.piece("Post", CHROME)
    bands = m.piece("Bands", MINT_C)
    cap = m.piece("Cap", CHROME_SHADE)
    bulb = m.piece("BulbGlobe", STAR_GLOW, material="Neon")
    disc(post, (0, 0, 0), 0.75, 0.3, segments=10, bevel=0.08)
    cylinder(post, (0, 0.3, 0), (0, 5.2, 0), 0.22, segments=8, radius_b=0.18)
    for y in (1.0, 4.4):
        cylinder(bands, (0, y - 0.12, 0), (0, y + 0.12, 0), 0.28, segments=8)
    revolve(cap, [(0.0, 0.0), (0.42, 0.0), (0.34, 0.22), (0.0, 0.26)], center=(0, 5.15, 0), segments=10)
    ellipsoid(bulb, (0, 5.95, 0), (0.62, 0.62, 0.62), rings=6, segments=10)
    revolve(cap, [(0.3, 0.0), (0.1, 0.25), (0.0, 0.3)], center=(0, 6.5, 0), segments=8)
    return m


def build_moon_tools():
    """
    Chrome pegboard rack on two legs with candy space tools hanging on pegs — a big wrench, a
    drill-beam gun (round, toy-like), a rock hammer and a scoop — plus a coral toolbox at its foot.
    """
    m = Model("M1_MoonTools", "ground centre of the rack; front -Z", budget=1500)
    frame = m.piece("Frame", CHROME_SHADE)
    board = m.piece("Board", NAVY)
    pegs = m.piece("Pegs", CHROME)
    mint = m.piece("ToolsMint", MINT_C, material="StudsSmall")
    sunny = m.piece("ToolsSunny", SUNNY, material="StudsSmall")
    coral = m.piece("ToolBox", CORAL_C)
    for sx in (-1, 1):
        cylinder(frame, (sx * 3.2, 0.0, 0.0), (sx * 3.2, 5.0, 0.0), 0.22, segments=8)
    block(board, (0, 3.2, 0.0), (6.0, 3.4, 0.3), bevel=0.08)
    face = -0.15
    for x, y in ((-2.2, 4.3), (-0.7, 4.3), (0.8, 4.3), (2.2, 4.3)):
        cylinder(pegs, (x, y, face), (x, y, face - 0.35), 0.07, segments=5)
    # Wrench: a handle with a ring head (mint).
    cylinder(mint, (-2.2, 4.1, face - 0.3), (-2.2, 2.3, face - 0.3), 0.13, segments=6)
    ring_tube(mint, (-2.2, 2.1, face - 0.3), 0.32, 0.16, 0.14, segments=10, axis="Z")
    # Drill-beam gun (sunny): a round body, a cone nozzle and a grip.
    ellipsoid(sunny, (-0.7, 3.5, face - 0.45), (0.55, 0.42, 0.32), rings=5, segments=8)
    cylinder(sunny, (-0.7, 3.0, face - 0.45), (-0.7, 2.4, face - 0.45), 0.16, segments=6)
    cylinder(mint, (-0.2, 3.5, face - 0.45), (0.25, 3.5, face - 0.45), 0.2, segments=6, radius_b=0.07)
    # Rock hammer (mint head, sunny handle) and scoop (sunny).
    cylinder(sunny, (0.8, 4.1, face - 0.3), (0.8, 2.5, face - 0.3), 0.11, segments=6)
    block(mint, (0.8, 2.45, face - 0.3), (0.9, 0.42, 0.42), bevel=0.12)
    cylinder(sunny, (2.2, 4.1, face - 0.3), (2.2, 3.0, face - 0.3), 0.11, segments=6)
    revolve(sunny, [(0.0, 0.0), (0.42, 0.12), (0.5, 0.5)], center=(2.2, 2.4, face - 0.3), segments=8)
    # Toolbox at the foot (front-right).
    block(coral, (2.2, 0.55, -1.2), (1.8, 1.1, 1.0), bevel=0.15)
    cylinder(pegs, (1.7, 1.25, -1.2), (2.7, 1.25, -1.2), 0.08, segments=5)
    return m


def build_flag_pole():
    """
    Flag pole with the SELL NUKES logo flag (spec §2.2: no country): a chrome pole on a round
    base with a star finial, a navy flag carrying "SELL" (sunshine) over "NUKES" (lime) in block
    letters on BOTH faces (R17) and a small yellow trefoil in the corner.
    """
    m = Model("M1_FlagPole", "ground centre of the pole; flag flies toward +X, faces -Z", budget=2200)
    pole = m.piece("Pole", CHROME)
    base = m.piece("Base", CHROME_SHADE)
    flag = m.piece("Flag", NAVY)
    sell = m.piece("LettersSell", SUNNY, material="Smooth")
    nukes = m.piece("LettersNukes", (150, 236, 70), material="Smooth")
    tip = m.piece("Finial", SUNNY, material="StudsSmall")
    disc(base, (0, 0, 0), 1.3, 0.5, segments=12, bevel=0.12)
    cylinder(pole, (0, 0.5, 0), (0, 13.0, 0), 0.24, segments=8)
    star(tip, (0, 13.6, 0), 0.6, 0.24, normal=(0, 0, -1))
    fw, fh, fd = 7.2, 4.2, 0.24
    fx, fy = 0.35 + fw / 2, 12.6 - fh / 2
    block(flag, (fx, fy, 0), (fw, fh, fd), bevel=0.06)
    for line, piece, dy in (("SELL", sell, 0.95), ("NUKES", nukes, -0.95)):
        cell = min(0.26, (fw - 1.2) / text_cells("NUKES"))
        for facing, z in (("-z", -fd / 2), ("+z", fd / 2)):
            block_text(piece, line, (fx, fy + dy, z), cell, 0.08, facing=facing)
    for sz in (-1, 1):
        trefoil(sell, (fx + fw / 2 - 0.7, fy + fh / 2 - 0.7, sz * (fd / 2 + 0.04)), 0.42, 0.06, normal=(0, 0, sz))
    return m


def build_solar_panels():
    """
    One solar panel on a stand (placed 3x): a chrome post, a sunny axle hub, and the tilting
    assembly — violet panel + raised navy cell bars + chrome frame, all named `Solar*` so WorldFx
    tilts them as ONE group. The assembly is symmetric about the axle, so its box centre sits on
    the axle and the tilt pivots there (R25).
    """
    m = Model("M1_SolarPanels", "ground centre of the stand; panel faces -Z (tilted toward the sky)", budget=900)
    post = m.piece("Post", CHROME_SHADE)
    hub = m.piece("Hub", SUNNY)
    panel = m.piece("SolarPanel", VIOLET)
    cells = m.piece("SolarCells", NAVY, material="Smooth")
    frame = m.piece("SolarFrame", CHROME)
    disc(post, (0, 0, 0), 0.9, 0.3, segments=10, bevel=0.08)
    cylinder(post, (0, 0.3, 0), (0, 3.1, 0), 0.25, segments=8)
    axle_y = 3.6
    cylinder(hub, (-0.5, axle_y, 0), (0.5, axle_y, 0), 0.36, segments=10)
    tilt = rot_x(-35)
    w, h = 5.2, 3.2
    block(panel, (0, axle_y, 0), (w, 0.18, h), bevel=0.04, rot=tilt)
    # Cell bars on the panel's top face (+0.13 proud), symmetric about the axle.
    for k in range(-2, 3):
        a = tilt @ Vector((k * 1.0, 0.13, 0.0))
        block(cells, (a.x, axle_y + a.y, a.z), (0.08, 0.06, h - 0.3), rot=tilt, bevel=0.0)
    for k in (-0.75, 0.75):
        c = tilt @ Vector((0.0, 0.13, k))
        block(cells, (c.x, axle_y + c.y, c.z), (w - 0.3, 0.06, 0.08), rot=tilt, bevel=0.0)
    # Frame: four bars round the panel edge, taller than the panel (R18).
    for sz in (-1, 1):
        c = tilt @ Vector((0.0, 0.0, sz * (h / 2 + 0.06)))
        block(frame, (c.x, axle_y + c.y, c.z), (w + 0.24, 0.32, 0.14), rot=tilt, bevel=0.04)
    for sx in (-1, 1):
        c = tilt @ Vector((sx * (w / 2 + 0.06), 0.0, 0.0))
        block(frame, (c.x, axle_y + c.y, c.z), (0.14, 0.32, h), rot=tilt, bevel=0.04)
    return m


def build_air_pump():
    """
    Air pump: a round mint air tank on three little feet with a chrome gauge dial (navy face,
    coral needle), a coiled violet hose to a chrome nozzle and a sunny hand-pump plunger on top.
    """
    m = Model("M1_AirPump", "ground centre of the tank; gauge faces -Z", budget=1400)
    tank = m.piece("Tank", MINT_C)
    chrome = m.piece("Chrome", CHROME)
    face = m.piece("GaugeFace", NAVY, material="Smooth")
    needle = m.piece("Needle", CORAL_C, material="Smooth")
    hose = m.piece("Hose", VIOLET)
    plunger = m.piece("Plunger", SUNNY)
    for i in range(3):
        a = math.radians(90 + 120 * i)
        cylinder(chrome, (1.2 * math.cos(a), 0.0, 1.2 * math.sin(a)), (0.9 * math.cos(a), 0.8, 0.9 * math.sin(a)), 0.16, segments=6)
    ellipsoid(tank, (0, 2.0, 0), (1.6, 1.5, 1.6), rings=8, segments=14)
    # Gauge on the front.
    cylinder(chrome, (0, 2.3, -1.45), (0, 2.3, -1.85), 0.62, segments=12)
    cylinder(face, (0, 2.3, -1.84), (0, 2.3, -1.9), 0.5, segments=12)
    block(needle, (0.12, 2.42, -1.93), (0.08, 0.38, 0.04), bevel=0.0, rot=rot_z(-30))
    # Plunger on top: a chrome barrel, a sunny rod and T-handle.
    cylinder(chrome, (0, 3.3, 0), (0, 4.3, 0), 0.32, segments=10)
    cylinder(plunger, (0, 4.3, 0), (0, 5.4, 0), 0.1, segments=6)
    cylinder(plunger, (-0.7, 5.45, 0), (0.7, 5.45, 0), 0.15, segments=8)
    # Coiled hose out of the side to a nozzle resting on the ground.
    path = []
    for i in range(13):
        t = i / 12
        a = t * 3 * math.pi
        path.append((1.6 + 0.45 * t + 0.25 * math.cos(a), 1.6 - 1.2 * t, 0.25 * math.sin(a) - 0.4 * t))
    tube(hose, path, 0.12, sides=6)
    cylinder(chrome, path[-1], (path[-1][0] + 0.5, path[-1][1] - 0.15, path[-1][2] - 0.2), 0.16, segments=6)
    return m


def build_bleep_bot():
    """
    Bleep Bot (M1 Manager, owner R30): a round chrome robot with a mint screen face showing two big
    happy eyes and a smile, a springy antenna with a sunny star tip, a coral tool belt, mint mitts
    and stubby chrome legs with round navy boots. R30 rig groups (belt rides the Torso, antenna +
    screen ride the Head).
    """
    from models._npc_rig import rig_split

    m = Model("M1_BleepBot", "ground centre between the feet; faces -Z", budget=3000)
    shell = m.piece("Shell", CHROME, material="Smooth")
    joints = m.piece("Joints", CHROME_SHADE, material="Smooth")
    mitts = m.piece("Mitts", MINT_C, material="Smooth")
    boots = m.piece("Boots", NAVY, material="Smooth")
    screen = m.piece("Screen", MINT_C, material="Smooth")
    face = m.piece("Face", INK_M, material="Smooth")
    belt = m.piece("Belt", CORAL_C, material="StudsSmall")
    antenna = m.piece("Antenna", SUNNY, material="Smooth")
    a = toon_biped(
        {"body": shell, "head": shell, "limbs": joints, "hands": mitts, "feet": boots},
        body=(1.35, 1.3, 1.25),
        head=(1.05, 0.9, 0.95),
        head_shape="dome",
        leg_h=1.2,
        arm_pose={"left": (14.0, 20.0), "right": (16.0, 35.0)},
    )
    hx, hy, hz = a["head"]
    hw, hh, hd = a["head_r"]
    front = a["head_front_z"]
    # Screen face: a rounded mint plate proud of the head front, eyes + smile on it.
    block(screen, (hx, hy, front - 0.05), (hw * 1.5, hh * 1.25, 0.12), bevel=0.05)
    for sx in (-1, 1):
        oriented_ellipsoid(face, (sx * 0.42, hy + 0.12, front - 0.13), (0.2, 0.28, 0.05), normal=(0, 0, -1), rings=4, segments=8)
    pts = []
    for k in range(7):
        ang = math.radians(200 + 140 * k / 6)
        pts.append((0.42 * math.cos(ang), hy - 0.15 + 0.3 * math.sin(ang), front - 0.13))
    tube(face, pts, 0.05, sides=4)
    # Ear bolts + antenna with a star tip.
    for sx in (-1, 1):
        cylinder(joints, (sx * hw * 0.98, hy, hz), (sx * (hw + 0.25), hy, hz), 0.28, segments=8)
    top = a["head_top"]
    tube(antenna, [(0.0, top - 0.1, hz), (0.15, top + 0.5, hz), (-0.1, top + 0.9, hz), (0.0, top + 1.2, hz)], 0.07, sides=5)
    star(antenna, (0.0, top + 1.45, hz), 0.38, 0.14, normal=(0, 0, -1))
    # Tool belt round the body's waist + a pouch.
    bx, by, bz = a["body_c"]
    bw, bh, bd = a["body"]
    yb = by - bh * 0.45
    rr = math.sqrt(max(0.1, 1 - (0.45) ** 2))
    revolve(belt, [(bw * rr + 0.05, -0.22), (bw * rr + 0.1, 0.0), (bw * rr + 0.05, 0.22)], center=(bx, yb, bz), segments=14, closed=True)
    block(belt, (bw * 0.55, yb - 0.1, bz - bd * rr * 0.85), (0.55, 0.55, 0.3), bevel=0.08)
    # Chest light ring (a mint ring on the chest front).
    ring_tube(mitts, (0.0, a["chest"][1] + 0.2, a["chest"][2] - 0.02), 0.32, 0.12, 0.1, segments=10, axis="Z")
    rig_split(m, toon_bones(a), assign={"Belt": "Torso", "Screen": "Head", "Antenna": "Head", "Face": "Head"})
    return m


def build_crater_rail():
    """Crater railing run: chrome posts with ball caps, a coral top rail and a mint low rail."""
    return rail_run("M1_CraterRail", CORAL_C, MINT_C)


BUILDERS = {
    "M1_Floor": build_floor,
    "M1_EntryArch": build_arch,
    "M1_CraterWall": build_crater_wall,
    "M1_RockCluster": build_rock_cluster,
    "M1_CapsuleBench": build_capsule_bench,
    "M1_CraterLamps": build_crater_lamps,
    "M1_MoonTools": build_moon_tools,
    "M1_FlagPole": build_flag_pole,
    "M1_SolarPanels": build_solar_panels,
    "M1_AirPump": build_air_pump,
    "M1_BleepBot": build_bleep_bot,
    "M1_CraterRail": build_crater_rail,
}
