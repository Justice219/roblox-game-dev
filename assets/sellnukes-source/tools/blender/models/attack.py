"""
attack.py — attack-mode art (spec §9): toy nuke projectiles tiers 1-5, the AA interceptor missile,
AA tower levels 1-5, the hex shield dome and the confetti mushroom-cloud puff.

Kid-friendly rules (spec §1): everything is a candy-coloured stud TOY. Rockets are chunky stud
rockets with a radiation trefoil badge and a glowing core band; the exhaust is a cartoon Neon
"candy flame" teardrop; the hit effect is a smiling cloud of puffs, stars and confetti — no fire or
smoke realism, no real weapons, no countries.

FLIGHT MODELS (NukeT1..NukeT5, Interceptor):
    ORIGIN = the rocket's centre (midway between nozzle and nose tip); the NOSE POINTS -Z, so the
    client renders a server-timed arc with `model:PivotTo(CFrame.lookAt(pos, pos + velocity))`.
    `Exhaust` (Neon) trails behind (+Z): flicker/scale it, add a Trail if wanted.
        NukeT1  4.5 studs  red body, white nose, yellow fins (3), green core
        NukeT2  5.5 studs  mint body, white nose, red fins (4), white stripe
        NukeT3  6.5 studs  purple body, yellow nose, pink fins, 2 stripes, 2 side boosters
        NukeT4  7.5 studs  orange body, white nose, blue fins, 2 stripes, 4 boosters, 2 core bands
        NukeT5  9.0 studs  gold body, pink nose, white fins, 4 boosters, crown ring, Neon star decals
        Interceptor 3.4 studs  slim white AA missile, sky-blue nose + fins, red band, blue exhaust

AA TOWERS (AATower1..AATower5): ORIGIN = ground centre; the barrels point -Z at rest.
    Turret* pieces yaw about joint "Turret" (axis +Y). Barrel* pieces pitch about joint "Barrel"
    (axis +X, a POSITIVE angle raises the muzzle) and ride on the turret yaw. Joints in the pivot.
        AATower1  "Pop Gun"        4.9 tall, 5 x 5 pad, single barrel
        AATower2  "Twin Popper"    6.8 tall, 6 x 6 pad, dome turret, twin barrels, beacon
        AATower3  "Truss Tower"    10.0 tall, 7 x 7 pad, lattice tower, twin barrels + radar dish
        AATower4  "Quad Blaster"   10.5 tall, round 8.4 pad, armoured tank tower, quad barrels, dish
        AATower5  "Mega Defender"  14.2 tall, 12 x 12 pad, corner pylons, gold tower, quad barrels,
                                   missile pods, big dish, Neon halo ring

ShieldDome: ONE translucent mesh (piece `Shield`, Glass, sky glow) — a hex-tile Goldberg dome of
    radius 50 (scale with Model:ScaleTo(r / 50) or set Shield.Size for an elliptical dome over a
    plot). Tiles are thin double-sided prisms with gaps, so the hex grid reads from inside and out.
    The runtime may switch Material to ForceField for a shimmer.

ConfettiCloud: cartoon "mushroom cloud" ~12 studs tall at scale 1 — a wide smiling puff cap, a
    short puffy stem, a puff ring, a ground skirt, Neon stars and three colours of confetti. Pieces
    are animation groups (tween each from small to full and fade): Base, Stem, Ring, Cap (+ CapFace,
    CapShine, CapBlush), Stars, ConfettiA/B/C. Joints give each group's centre.

Budgets: rockets <= 3,000; interceptor <= 1,000; towers 1,600-5,500; dome <= 3,000; cloud <= 5,000.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import (
    CONCRETE,
    DARK_STEEL,
    DEEP_BLUE,
    GLOW_GREEN,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    MINT,
    Model,
    ORANGE,
    PINK,
    PURPLE,
    SKY_BLUE,
    TOY_RED,
    YELLOW,
)
from snkit.kit import block, disc, hazard_band, hazard_floor, hazard_ring, tank, trefoil, truss
from snkit.shapes import cylinder, ellipsoid, prism, revolve, rot_x

from models._critter_kit import (
    GOLD,
    GOLD_DARK,
    HOT_PINK,
    SKY_GLOW,
    SNOW,
    SOFT_BLACK,
    SUN_GLOW,
    joints_text,
    plate,
    smile,
    star,
    transform_model,
    tube,
    tup,
    eyes,
    oriented_ellipsoid,
    surface,
)

EXHAUST = (255, 170, 60)  # candy-flame orange (Neon)


# ------------------------------------------------------------------------------------------------
# Rockets (built nose-up from y = 0, then laid nose-forward -Z and centred)
# ------------------------------------------------------------------------------------------------


def _face_side(sx):
    """Rotation turning a Y-axis revolve into a disc facing +X (sx = 1) or -X (sx = -1)."""
    from snkit.shapes import rot_z

    return rot_z(-90 if sx > 0 else 90)


def _rocket(m, length, r, body_col, nose_col, fin_col, fins=4, stripes=0, boosters=0, cores=1,
            crown_ring=False, stars=False):
    """
    Chunky stud rocket, nose up (+Y), nozzle bottom at y = 0. Pieces: Body, Nose, Fins, Trim
    (nozzle + booster nozzles), Core (Neon band), Badge + Trefoil (both sides), Exhaust (Neon
    candy flame below the nozzle), Stripes (white bands), Stars (Neon decals).
    """
    L = length
    body = m.piece("Body", body_col, material="Studs")
    nose = m.piece("Nose", nose_col, material="StudsSmall")
    fin = m.piece("Fins", fin_col, material="StudsSmall")
    trim = m.piece("Trim", DARK_STEEL, material="StudsSmall")
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    y0, y1 = 0.12 * L, 0.72 * L
    # Nozzle bell.
    revolve(trim, [(0.0, 0.0), (r * 0.62, 0.0), (r * 0.5, y0 * 0.6), (r * 0.66, y0 + 0.05), (0.0, y0 + 0.05)], segments=14)
    # Body: slight taper at the tail, flat shoulder under the nose.
    revolve(body, [(0.0, y0), (r * 0.82, y0), (r * 0.96, y0 + 0.08 * L), (r, y0 + 0.18 * L), (r, y1), (0.0, y1)], segments=16)
    # Rounded nose cone.
    nl = L - y1
    revolve(nose, [(0.0, y1), (r * 1.02, y1), (r * 0.95, y1 + nl * 0.35), (r * 0.7, y1 + nl * 0.7), (r * 0.34, y1 + nl * 0.93), (0.0, L)], segments=16)
    # Neon core band(s).
    for k in range(cores):
        yc = y0 + (0.38 + 0.18 * k) * (y1 - y0)
        revolve(core, [(r * 0.97, yc - 0.06 * L), (r * 1.07, yc - 0.045 * L), (r * 1.07, yc + 0.045 * L), (r * 0.97, yc + 0.06 * L)], segments=16, closed=True)
    if stripes:
        st = m.piece("Stripes", SNOW, material="StudsSmall")
        for k in range(stripes):
            ys = y0 + (0.15 if k == 0 else 0.86) * (y1 - y0)
            revolve(st, [(r * 0.97, ys - 0.035 * L), (r * 1.05, ys - 0.025 * L), (r * 1.05, ys + 0.025 * L), (r * 0.97, ys + 0.035 * L)], segments=16, closed=True)
    # Fins: chunky trapezoids in the planes through the axis.
    for i in range(fins):
        a = 2 * math.pi * i / fins + (math.pi / 4 if fins == 4 else math.pi / 2)
        dx, dz = math.cos(a), math.sin(a)
        r0, r1 = r * 0.85, r * 1.9
        outline = [
            (dx * r0, y0 + 0.02 * L, dz * r0),
            (dx * r1, 0.01 * L, dz * r1),
            (dx * r1 * 0.96, y0 + 0.08 * L, dz * r1 * 0.96),
            (dx * r0, y0 + 0.3 * L, dz * r0),
        ]
        prism(fin, outline, (-dz, 0, dx), max(0.18, r * 0.3))
    # Badges: yellow disc + black trefoil on both sides (visible in a side-on arc).
    badge = m.piece("Badge", HAZARD_YELLOW, material="Smooth")
    mark = m.piece("Trefoil", HAZARD_BLACK, material="Smooth")
    yb = y0 + 0.66 * (y1 - y0)
    for sx in (-1, 1):
        revolve(badge, [(0.0, -0.05), (r * 0.5, -0.05), (r * 0.55, 0.0), (r * 0.5, 0.05), (0.0, 0.05)], center=(sx * (r - 0.01), yb, 0), segments=16, rot=_face_side(sx))
        trefoil(mark, (sx * (r + 0.07), yb, 0), r * 0.44, 0.04, normal=(sx, 0, 0))
    # Candy flame exhaust (two nested teardrops in one Neon piece).
    ex = m.piece("Exhaust", EXHAUST, material="Neon")
    revolve(ex, [(0.0, 0.02), (r * 0.5, -0.03 * L), (r * 0.46, -0.14 * L), (r * 0.24, -0.3 * L), (0.0, -0.4 * L)], segments=12)
    # Side boosters (body colour, nose colour caps, dark nozzles).
    for b in range(boosters):
        a = 2 * math.pi * b / boosters + (0 if boosters == 2 else math.pi / 4) + math.pi / 2 * (boosters == 2)
        cx, cz = math.cos(a) * r * 1.3, math.sin(a) * r * 1.3
        br_ = r * 0.36
        revolve(body, [(0.0, 0.08 * L), (br_, 0.08 * L), (br_, 0.42 * L), (0.0, 0.42 * L)], center=(cx, 0, cz), segments=10)
        revolve(nose, [(0.0, 0.42 * L), (br_ * 1.02, 0.42 * L), (br_ * 0.7, 0.5 * L), (0.0, 0.55 * L)], center=(cx, 0, cz), segments=10)
        revolve(trim, [(0.0, 0.03 * L), (br_ * 0.8, 0.03 * L), (br_ * 0.9, 0.09 * L), (0.0, 0.09 * L)], center=(cx, 0, cz), segments=10)
        revolve(ex, [(0.0, 0.04 * L), (br_ * 0.7, 0.0), (br_ * 0.5, -0.1 * L), (0.0, -0.18 * L)], center=(cx, 0, cz), segments=8)
        # Strut tying the booster to the core stage.
        tube(trim, [(cx * 0.7, 0.3 * L, cz * 0.7), (cx, 0.3 * L, cz)], br_ * 0.35, sides=5)
    if crown_ring:
        gold = m.piece("Crown", GOLD_DARK, material="StudsSmall")
        yr = y1 + 0.05 * L
        revolve(gold, [(r * 0.96, yr - 0.05 * L), (r * 1.1, yr - 0.04 * L), (r * 1.1, yr + 0.04 * L), (r * 0.9, yr + 0.05 * L)], segments=16, closed=True)
        for k in range(6):
            a = 2 * math.pi * k / 6
            dx, dz = math.cos(a), math.sin(a)
            plate(gold, [(-0.18 * r, 0), (0.18 * r, 0), (0, 0.35 * r)], (dx * r * 1.0, yr + 0.03 * L, dz * r * 1.0), (dx, 0.0, dz), (0, 1, 0), 0.08)
    if stars:
        sp = m.piece("Stars", SUN_GLOW, material="Neon")
        for k in range(4):
            a = 2 * math.pi * k / 4 + math.pi / 4
            dx, dz = math.cos(a), math.sin(a)
            ys = y0 + 0.3 * (y1 - y0)
            star(sp, (dx * (r + 0.03), ys, dz * (r + 0.03)), r * 0.28, 0.05, normal=(dx, 0, dz))


def _lay_flat(m, length):
    """Turn a nose-up rocket nose-forward (-Z) and centre it (midway nozzle -> nose) on the origin."""
    transform_model(m, rot_x(-90), offset=(0.0, 0.0, length / 2))


def _nuke(key, tier, length, r, body, nose, fins_col, **kw):
    m = Model(key, "", budget=3000)
    _rocket(m, length, r, body, nose, fins_col, **kw)
    _lay_flat(m, length)
    m.pivot = (
        f"rocket centre (midway nozzle -> nose); nose toward -Z (PivotTo(CFrame.lookAt(pos, pos + vel))); "
        f"attack nuke tier {tier}; length {length:g}; Exhaust trails toward +Z"
    )
    return m


def build_nuke_t1():
    """Tier 1: small red candy rocket, white nose, three yellow fins."""
    return _nuke("NukeT1", 1, 4.5, 0.62, TOY_RED, SNOW, YELLOW, fins=3)


def build_nuke_t2():
    """Tier 2: mint rocket, white nose, four red fins, one white stripe."""
    return _nuke("NukeT2", 2, 5.5, 0.72, MINT, SNOW, TOY_RED, fins=4, stripes=1)


def build_nuke_t3():
    """Tier 3: purple rocket, yellow nose, pink fins, two stripes, two side boosters."""
    return _nuke("NukeT3", 3, 6.5, 0.82, PURPLE, YELLOW, HOT_PINK, fins=4, stripes=2, boosters=2)


def build_nuke_t4():
    """Tier 4: orange rocket, white nose, blue fins, two stripes, four boosters, double core."""
    return _nuke("NukeT4", 4, 7.5, 0.92, ORANGE, SNOW, DEEP_BLUE, fins=4, stripes=2, boosters=4, cores=2)


def build_nuke_t5():
    """Tier 5: gold mega rocket, pink nose, white fins, four boosters, crown ring, Neon stars."""
    return _nuke("NukeT5", 5, 9.0, 1.05, GOLD, HOT_PINK, SNOW, fins=4, stripes=2, boosters=4, cores=2, crown_ring=True, stars=True)


def build_interceptor():
    """AA interceptor: slim white missile, sky-blue nose + fins, red band, blue Neon exhaust."""
    m = Model("Interceptor", "", budget=1000)
    L, r = 3.4, 0.26
    body = m.piece("Body", SNOW, material="StudsSmall")
    nose = m.piece("Nose", SKY_BLUE, material="StudsSmall")
    fins = m.piece("Fins", SKY_BLUE, material="StudsSmall")
    band = m.piece("Band", TOY_RED, material="Smooth")
    ex = m.piece("Exhaust", SKY_GLOW, material="Neon")
    revolve(body, [(0.0, 0.0), (r * 0.8, 0.0), (r, 0.1), (r, 0.75 * L), (0.0, 0.75 * L)], segments=10)
    revolve(nose, [(0.0, 0.75 * L), (r * 1.02, 0.75 * L), (r * 0.8, 0.86 * L), (r * 0.35, 0.97 * L), (0.0, L)], segments=10)
    revolve(band, [(r * 0.97, 0.55 * L), (r * 1.08, 0.56 * L), (r * 1.08, 0.62 * L), (r * 0.97, 0.63 * L)], segments=10, closed=True)
    for i in range(4):
        a = math.pi / 4 + i * math.pi / 2
        dx, dz = math.cos(a), math.sin(a)
        outline = [(dx * r * 0.8, 0.02, dz * r * 0.8), (dx * r * 2.6, 0.0, dz * r * 2.6), (dx * r * 2.4, 0.35, dz * r * 2.4), (dx * r * 0.8, 0.8, dz * r * 0.8)]
        prism(fins, outline, (-dz, 0, dx), 0.08)
        canard = [(dx * r * 0.8, 0.62 * L, dz * r * 0.8), (dx * r * 1.8, 0.64 * L, dz * r * 1.8), (dx * r * 0.8, 0.72 * L, dz * r * 0.8)]
        prism(fins, canard, (-dz, 0, dx), 0.06)
    revolve(ex, [(0.0, 0.02), (r * 0.7, -0.08), (r * 0.5, -0.45), (0.0, -0.9)], segments=8)
    _lay_flat(m, L)
    m.pivot = (
        "missile centre (midway tail -> nose); nose toward -Z (PivotTo(CFrame.lookAt(pos, pos + vel))); "
        "AA interceptor; length 3.4; Exhaust trails toward +Z"
    )
    return m


# ------------------------------------------------------------------------------------------------
# AA towers
# ------------------------------------------------------------------------------------------------


def _pad(m, size, height=0.8, round_pad=False):
    """Concrete pad with hazard stripes on its sides (square) or a hazard ring on top (round)."""
    base = m.piece("Base", CONCRETE, material="Studs")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW, material="Studs")
    black = m.piece("HazardBlack", HAZARD_BLACK, material="Studs")
    if round_pad:
        disc(base, (0, 0, 0), size / 2, height, segments=24, bevel=0.15)
        hazard_ring(yellow, black, (0, 0, 0), size / 2 - 1.2, size / 2 - 0.2, height - 0.02, height + 0.08, count=20)
    else:
        block(base, (0, height / 2, 0), (size, height, size), bevel=0.15)
        h = height * 0.55
        for sz in (-1, 1):
            hazard_band(yellow, black, (0, height * 0.45, sz * (size / 2 + 0.03)), (size - 0.6, h, 0.1), stripe=0.6, axis="x")
            hazard_band(yellow, black, (sz * (size / 2 + 0.03), height * 0.45, 0), (size - 0.6, h, 0.1), stripe=0.6, axis="z")
    return base, yellow, black


def _barrels(m, trunnion, count, length, radius, spread=0.5, tip_col=TOY_RED, brakes=False):
    """Barrel group: `count` (1, 2 or 4) barrels from the trunnion toward -Z, red muzzle rings."""
    barrel = m.piece("Barrel", DARK_STEEL, material="StudsSmall")
    tip = m.piece("BarrelTip", tip_col, material="StudsSmall")
    tx, ty, tz = trunnion
    if count == 1:
        offsets = [(0.0, 0.0)]
    elif count == 2:
        offsets = [(-spread, 0.0), (spread, 0.0)]
    else:
        offsets = [(-spread, -spread * 0.6), (spread, -spread * 0.6), (-spread, spread * 0.6), (spread, spread * 0.6)]
    # Breech block that the barrels plug into (pitches with them).
    block(barrel, (tx, ty, tz - 0.2), (max(1.0, spread * 2 + radius * 3), max(0.8, spread * 1.2 + radius * 3) if count == 4 else radius * 3.2, 1.0), bevel=0.1)
    for ox, oy in offsets:
        a = (tx + ox, ty + oy, tz - 0.5)
        b = (tx + ox, ty + oy, tz - length)
        cylinder(barrel, a, b, radius, segments=10)
        cylinder(tip, (tx + ox, ty + oy, tz - length + 0.05), (tx + ox, ty + oy, tz - length - 0.35), radius * 1.4, segments=10)
        if brakes:
            cylinder(tip, (tx + ox, ty + oy, tz - length * 0.55), (tx + ox, ty + oy, tz - length * 0.55 - 0.22), radius * 1.25, segments=10)
    m.joints["Barrel"] = trunnion


def _dish(piece, center, radius, facing=(0.0, 0.35, 1.0)):
    """
    Radar dish: shallow bowl (revolve, thick rim) + feed tripod + mast stub, built about +Y in a
    scratch Piece and then rotated so its axis points along `facing`, moved to `center`.
    """
    from snkit.core import Piece, br
    from snkit.shapes import add_faces

    tmp = Piece("DishTmp", (0, 0, 0))
    r = radius
    revolve(tmp, [(0.0, 0.0), (r * 0.5, 0.06 * r), (r, 0.3 * r), (r * 1.02, 0.36 * r), (r * 0.94, 0.38 * r), (r * 0.46, 0.14 * r), (0.0, 0.08 * r)], segments=16)
    for sx in (-1, 1):
        tube(tmp, [(sx * r * 0.8, 0.32 * r, 0.0), (0.0, 0.8 * r, 0.0)], 0.04 * r + 0.03, sides=4)
    ellipsoid(tmp, (0.0, 0.82 * r, 0.0), (0.09 * r + 0.05,) * 3, rings=4, segments=8)
    cylinder(tmp, (0.0, -0.4 * r, 0.0), (0.0, 0.05, 0.0), 0.08 * r + 0.06, segments=8)
    tmp.bm.verts.index_update()
    rot = Vector((0, 1, 0)).rotation_difference(Vector(facing).normalized()).to_matrix()
    c = Vector(center)
    verts = [tup(rot @ Vector(br(v.co)) + c) for v in tmp.bm.verts]
    faces = [tuple(v.index for v in f.verts) for f in tmp.bm.faces]
    add_faces(piece, verts, faces)
    tmp.bm.free()


def _tower_model(key, level, name, budget):
    m = Model(key, "", budget=budget)
    m.joints = {}
    m.level = level
    m.title = name
    return m


def _tower_done(m):
    m.pivot = (
        f"ground centre of the AA tower pad; barrels point -Z at rest; AA tower level {m.level} \"{m.title}\"; "
        f"Turret* yaw about +Y, Barrel* pitch about +X (positive raises the muzzle); {joints_text(m.joints)}"
    )
    return m


def build_aa_tower_1():
    """Level 1 "Pop Gun": small pad, red stud post, white turret, one barrel."""
    m = _tower_model("AATower1", 1, "Pop Gun", 1800)
    _pad(m, 5.0, 0.7)
    tower = m.piece("Tower", TOY_RED, material="Studs")
    trim = m.piece("TowerTrim", SNOW, material="StudsSmall")
    revolve(tower, [(0.0, 0.7), (1.1, 0.7), (1.1, 0.95), (0.85, 1.2), (0.85, 3.4), (0.0, 3.4)], segments=16)
    for y in (1.6, 2.7):
        revolve(trim, [(0.84, y - 0.15), (0.98, y - 0.12), (0.98, y + 0.12), (0.84, y + 0.15)], segments=16, closed=True)
    turret = m.piece("Turret", SNOW, material="Studs")
    ttrim = m.piece("TurretTrim", DARK_STEEL, material="StudsSmall")
    disc(ttrim, (0, 3.35, 0), 1.0, 0.3, segments=16)
    block(turret, (0, 4.2, 0.2), (2.0, 1.4, 2.2), bevel=0.3, segments=2)
    for sx in (-1, 1):
        block(ttrim, (sx * 0.95, 4.15, -0.3), (0.25, 0.8, 0.8), bevel=0.08)
    m.joints["Turret"] = (0.0, 3.4, 0.0)
    _barrels(m, (0.0, 4.15, -0.6), 1, 2.6, 0.26)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    for sx in (-1, 1):
        for sz in (-1, 1):
            ellipsoid(glow, (sx * 2.0, 0.75, sz * 2.0), (0.22, 0.16, 0.22), rings=4, segments=8)
    return _tower_done(m)


def build_aa_tower_2():
    """Level 2 "Twin Popper": taller blue post, dome turret, twin barrels, red beacon."""
    m = _tower_model("AATower2", 2, "Twin Popper", 2400)
    _pad(m, 6.0, 0.8)
    tower = m.piece("Tower", SKY_BLUE, material="Studs")
    trim = m.piece("TowerTrim", SNOW, material="StudsSmall")
    revolve(tower, [(0.0, 0.8), (1.4, 0.8), (1.4, 1.1), (1.0, 1.5), (1.0, 4.6), (1.25, 4.8), (0.0, 4.8)], segments=16)
    for y in (2.0, 3.0, 4.0):
        revolve(trim, [(0.99, y - 0.14), (1.12, y - 0.1), (1.12, y + 0.1), (0.99, y + 0.14)], segments=16, closed=True)
    turret = m.piece("Turret", SNOW, material="Studs")
    ttrim = m.piece("TurretTrim", SKY_BLUE, material="StudsSmall")
    revolve(turret, [(0.0, 4.8), (1.5, 4.8), (1.55, 5.3), (1.3, 6.0), (0.8, 6.4), (0.0, 6.5)], segments=18)
    block(ttrim, (0, 5.5, -1.15), (1.8, 0.5, 0.5), bevel=0.12)  # visor
    for sx in (-1, 1):
        block(ttrim, (sx * 1.35, 5.35, -0.3), (0.3, 1.0, 1.0), bevel=0.08)
    beacon = m.piece("TurretGlow", TOY_RED, material="Neon")
    ellipsoid(beacon, (0, 6.62, 0.1), (0.24, 0.22, 0.24), rings=5, segments=10)
    m.joints["Turret"] = (0.0, 4.8, 0.0)
    _barrels(m, (0.0, 5.35, -0.8), 2, 3.0, 0.25, spread=0.55)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    for sx in (-1, 1):
        for sz in (-1, 1):
            ellipsoid(glow, (sx * 2.4, 0.85, sz * 2.4), (0.24, 0.18, 0.24), rings=4, segments=8)
    return _tower_done(m)


def build_aa_tower_3():
    """Level 3 "Truss Tower": yellow lattice tower, steel deck, blue turret, twin barrels, radar dish."""
    m = _tower_model("AATower3", 3, "Truss Tower", 3200)
    _pad(m, 7.0, 0.8)
    tower = m.piece("Tower", HAZARD_YELLOW, material="StudsSmall")
    truss(tower, (0, 0.8, 0), (0, 6.6, 0), 2.6, member=0.24, bays=4)
    trim = m.piece("TowerTrim", DARK_STEEL, material="Studs")
    block(trim, (0, 6.75, 0), (3.6, 0.4, 3.6), bevel=0.1)
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(trim, (sx * 1.3, 1.0, sz * 1.3), (0.7, 0.4, 0.7), bevel=0.08)  # feet
    turret = m.piece("Turret", SKY_BLUE, material="Studs")
    ttrim = m.piece("TurretTrim", SNOW, material="StudsSmall")
    disc(ttrim, (0, 6.95, 0), 1.3, 0.35, segments=16)
    block(turret, (0, 7.95, 0.3), (2.6, 1.7, 2.8), bevel=0.3, segments=2)
    for sx in (-1, 1):
        block(ttrim, (sx * 1.38, 7.9, -0.5), (0.3, 1.0, 1.0), bevel=0.08)
    dish = m.piece("TurretDish", SNOW, material="StudsSmall")
    _dish(dish, (0.0, 8.95, 1.1), 0.95, facing=(0.0, 0.5, 1.0))
    m.joints["Turret"] = (0.0, 6.95, 0.0)
    _barrels(m, (0.0, 7.9, -0.9), 2, 3.4, 0.26, spread=0.6, brakes=True)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    for sx in (-1, 1):
        for sz in (-1, 1):
            ellipsoid(glow, (sx * 1.75, 6.95, sz * 1.75), (0.2, 0.2, 0.2), rings=4, segments=8)
            ellipsoid(glow, (sx * 2.9, 0.85, sz * 2.9), (0.24, 0.18, 0.24), rings=4, segments=8)
    return _tower_done(m)


def build_aa_tower_4():
    """Level 4 "Quad Blaster": round hazard pad, purple armoured tower, big turret, quad barrels, dish."""
    m = _tower_model("AATower4", 4, "Quad Blaster", 4000)
    _pad(m, 8.4, 0.9, round_pad=True)
    tower = m.piece("Tower", PURPLE, material="Studs")
    trim = m.piece("TowerTrim", GOLD, material="StudsSmall")
    tank(tower, trim, (0, 0.9, 0), 1.7, 5.6, segments=18, band_count=3)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    revolve(glow, [(1.68, 3.1), (1.78, 3.16), (1.78, 3.34), (1.68, 3.4)], segments=18, closed=True)
    for k in range(6):
        a = 2 * math.pi * k / 6
        ellipsoid(glow, (math.cos(a) * 3.3, 0.95, math.sin(a) * 3.3), (0.24, 0.16, 0.24), rings=4, segments=8)
    turret = m.piece("Turret", SNOW, material="Studs")
    ttrim = m.piece("TurretTrim", PURPLE, material="StudsSmall")
    disc(ttrim, (0, 6.7, 0), 1.6, 0.4, segments=18)
    block(turret, (0, 7.9, 0.3), (3.4, 2.1, 3.4), bevel=0.35, segments=2)
    block(ttrim, (0, 8.98, 0.3), (2.6, 0.2, 2.6), bevel=0.08)
    for sx in (-1, 1):
        block(ttrim, (sx * 1.78, 7.8, -0.6), (0.34, 1.3, 1.3), bevel=0.1)
    dish = m.piece("TurretDish", SNOW, material="StudsSmall")
    _dish(dish, (0.0, 9.4, 1.3), 1.05, facing=(0.0, 0.55, 1.0))
    m.joints["Turret"] = (0.0, 6.7, 0.0)
    _barrels(m, (0.0, 7.8, -1.1), 4, 3.8, 0.24, spread=0.55, brakes=True)
    return _tower_done(m)


def build_aa_tower_5():
    """Level 5 "Mega Defender": big hazard pad, corner pylons, gold tower, quad barrels, pods, halo."""
    m = _tower_model("AATower5", 5, "Mega Defender", 5500)
    base, yellow, black = _pad(m, 12.0, 1.0)
    hazard_floor(yellow, black, (0, 1.04, 0), (11.0, 11.0), 0.08, stripe=1.2, inset=0.0)
    disc(base, (0, 1.0, 0), 3.2, 0.5, segments=24)
    tower = m.piece("Tower", GOLD, material="Studs")
    trim = m.piece("TowerTrim", SNOW, material="Studs")
    revolve(tower, [(0.0, 1.5), (2.6, 1.5), (2.6, 2.2), (2.0, 2.8), (2.0, 6.0), (1.7, 6.4), (1.7, 9.2), (2.1, 9.6), (0.0, 9.6)], segments=20)
    for y in (3.4, 4.8, 7.6):
        revolve(trim, [(1.99 if y < 6 else 1.69, y - 0.22), ((2.16 if y < 6 else 1.86), y - 0.16), ((2.16 if y < 6 else 1.86), y + 0.16), ((1.99 if y < 6 else 1.69), y + 0.22)], segments=20, closed=True)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    for sx in (-1, 1):  # corner pylons with glowing tips
        for sz in (-1, 1):
            x, z = sx * 4.6, sz * 4.6
            revolve(trim, [(0.0, 1.0), (0.7, 1.0), (0.55, 1.4), (0.45, 4.2), (0.0, 4.3)], center=(x, 0, z), segments=10)
            ellipsoid(glow, (x, 4.45, z), (0.32, 0.32, 0.32), rings=5, segments=10)
    for side in (-1, 1):  # trefoil badges on the tower
        trefoil(glow, (side * 2.04, 4.1, 0), 0.7, 0.06, normal=(side, 0, 0))
    halo = [(math.cos(2 * math.pi * i / 28) * 3.0, 8.4, math.sin(2 * math.pi * i / 28) * 3.0) for i in range(28)]
    tube(glow, halo, 0.12, sides=6, closed=True)
    turret = m.piece("Turret", SNOW, material="Studs")
    ttrim = m.piece("TurretTrim", GOLD_DARK, material="StudsSmall")
    disc(ttrim, (0, 9.6, 0), 2.0, 0.45, segments=20)
    revolve(turret, [(0.0, 10.0), (2.2, 10.0), (2.3, 10.7), (1.9, 11.7), (1.1, 12.3), (0.0, 12.45)], segments=20)
    for sx in (-1, 1):  # missile pods on the turret sides (red-nosed mini rockets)
        block(ttrim, (sx * 2.6, 11.0, 0.0), (1.0, 1.3, 2.2), bevel=0.15)
        for oy in (-0.3, 0.3):
            for ox in (-0.22, 0.22):
                cylinder(turret, (sx * 2.6 + ox, 11.0 + oy, -1.1), (sx * 2.6 + ox, 11.0 + oy, -1.35), 0.18, segments=8)
    dish = m.piece("TurretDish", SNOW, material="StudsSmall")
    _dish(dish, (0.0, 12.7, 1.3), 1.4, facing=(0.0, 0.6, 1.0))
    m.joints["Turret"] = (0.0, 9.6, 0.0)
    _barrels(m, (0.0, 11.0, -1.4), 4, 4.6, 0.3, spread=0.7, brakes=True)
    return _tower_done(m)


# ------------------------------------------------------------------------------------------------
# Shield dome (hex Goldberg dome, one translucent mesh)
# ------------------------------------------------------------------------------------------------

DOME_RADIUS = 50.0


def _icosphere(frequency):
    """Geodesic sphere (unit) with a vertex at +Y: returns (vertices: [Vector], triangles: [(i,j,k)])."""
    t = math.atan(0.5)
    base = [Vector((0, 1, 0))]
    for k in range(5):
        a = 2 * math.pi * k / 5
        base.append(Vector((math.cos(t) * math.cos(a), math.sin(t), math.cos(t) * math.sin(a))))
    for k in range(5):
        a = 2 * math.pi * k / 5 + math.pi / 5
        base.append(Vector((math.cos(t) * math.cos(a), -math.sin(t), math.cos(t) * math.sin(a))))
    base.append(Vector((0, -1, 0)))
    faces = []
    for k in range(5):
        u0, u1 = 1 + k, 1 + (k + 1) % 5
        l0, l1 = 6 + k, 6 + (k + 1) % 5
        faces += [(0, u1, u0), (u0, u1, l0), (u1, l1, l0), (11, l0, l1)]
    verts, index = [], {}

    def vid(p):
        p = p.normalized()
        key = (round(p.x, 5), round(p.y, 5), round(p.z, 5))
        if key not in index:
            index[key] = len(verts)
            verts.append(p)
        return index[key]

    tris = []
    f = frequency
    for a, b, c in faces:
        A, B, C = base[a], base[b], base[c]
        grid = {}
        for i in range(f + 1):
            for j in range(f + 1 - i):
                grid[(i, j)] = vid(A + (B - A) * (i / f) + (C - A) * (j / f))
        for i in range(f):
            for j in range(f - i):
                tris.append((grid[(i, j)], grid[(i + 1, j)], grid[(i, j + 1)]))
                if i + j < f - 1:
                    tris.append((grid[(i + 1, j)], grid[(i + 1, j + 1)], grid[(i, j + 1)]))
    return verts, tris


def build_shield_dome():
    """Hex-tile Goldberg dome (radius 50), thin double-sided tiles with gaps; ONE Glass piece."""
    m = Model("ShieldDome", "", budget=3000)
    shield = m.piece("Shield", SKY_GLOW, material="Glass", transparency=0.55)
    verts, tris = _icosphere(4)
    around = {i: [] for i in range(len(verts))}
    for tri in tris:
        centroid = (verts[tri[0]] + verts[tri[1]] + verts[tri[2]]).normalized()
        for i in tri:
            around[i].append(centroid)
    gap = 0.9  # tile size relative to its full Voronoi cell (0.9 = 10 % gaps)
    thick = 0.012  # of the radius (0.6 studs at radius 50)
    for i, centre in enumerate(verts):
        if centre.y < -0.06:
            continue
        cells = around[i]
        n = centre
        ref = Vector((1, 0, 0)) if abs(n.x) < 0.9 else Vector((0, 0, 1))
        u = (ref - n * ref.dot(n)).normalized()
        w = n.cross(u)
        cells.sort(key=lambda p: math.atan2((p - n).dot(w), (p - n).dot(u)))
        ring = []
        for p in cells:
            q = n + (p - n) * gap
            q = q.normalized() * DOME_RADIUS
            q.y = max(q.y, 0.0)  # tiles that dip under the ground are flattened onto it
            ring.append(tup(q))
        prism(shield, ring, tup(n), DOME_RADIUS * thick)
    m.pivot = (
        f"ground centre of the dome; hex Goldberg dome radius {DOME_RADIUS:g} (scale: Model:ScaleTo(r / {DOME_RADIUS:g}) or set "
        "Shield.Size for an elliptical dome); one Glass piece, may be switched to ForceField at runtime"
    )
    return m


# ------------------------------------------------------------------------------------------------
# Confetti mushroom cloud
# ------------------------------------------------------------------------------------------------


def build_confetti_cloud():
    """
    Cartoon hit effect: a WIDE smiling puff cap (one big soft dome ringed with puffs), a short puffy
    stem, a white puff ring, a cream ground skirt, Neon stars and three colours of confetti.
    Warm yellow / lime / white candy colours so it reads as a party pop, not smoke or a tree.
    """
    m = Model("ConfettiCloud", "", budget=5000)
    joints = {}
    base = m.piece("Base", (255, 248, 226), material="Studs")
    for k in range(8):  # ground skirt: low puffs in a wide ring
        a = 2 * math.pi * k / 8 + 0.2
        r = 3.0 + 0.4 * (k % 2)
        ellipsoid(base, (math.cos(a) * r, 0.7, math.sin(a) * r), (1.35, 0.8, 1.35), rings=5, segments=10)
    ellipsoid(base, (0, 0.9, 0), (2.4, 1.0, 2.4), rings=6, segments=12)
    joints["Base"] = (0, 0.8, 0)
    stem = m.piece("Stem", (206, 255, 150), material="Studs")
    for k, y in enumerate((2.1, 3.2, 4.3, 5.3)):
        r = 1.45 - 0.08 * k
        ellipsoid(stem, (0.15 * math.sin(k * 2.1), y, 0.15 * math.cos(k * 1.3)), (r, 0.85, r), rings=6, segments=12)
    joints["Stem"] = (0, 3.7, 0)
    ring = m.piece("Ring", SNOW, material="Studs")
    for k in range(9):
        a = 2 * math.pi * k / 9
        ellipsoid(ring, (math.cos(a) * 2.1, 3.9 + 0.12 * math.sin(3 * a), math.sin(a) * 2.1), (0.75, 0.48, 0.75), rings=5, segments=8)
    joints["Ring"] = (0, 3.9, 0)
    cap = m.piece("Cap", (255, 228, 112), material="Studs")
    # One big soft dome (the mushroom cap) ...
    ellipsoid(cap, (0, 7.6, 0), (4.6, 2.5, 4.6), rings=8, segments=18, deform=lambda x, y, z: (x, max(y, -1.4), z))
    # ... ringed by rim puffs and a few crown puffs on top.
    for k in range(10):
        a = 2 * math.pi * k / 10
        ellipsoid(cap, (math.cos(a) * 4.5, 6.6 + 0.2 * (k % 2), math.sin(a) * 4.5), (1.25, 1.0, 1.25), rings=5, segments=8)
    for k in range(4):
        a = 2 * math.pi * k / 4 + 0.6
        ellipsoid(cap, (math.cos(a) * 2.0, 9.6, math.sin(a) * 2.0), (1.3, 1.0, 1.3), rings=5, segments=8)
    joints["Cap"] = (0, 7.6, 0)
    face = m.piece("CapFace", SOFT_BLACK, material="Smooth")
    shine = m.piece("CapShine", SNOW, material="Smooth")
    fc, fr = (0, 7.6, 0), (4.6, 2.5, 4.6)
    eyes(face, shine, fc, fr, yaw=14, pitch=12, size=0.5, tall=1.25)
    smile(face, fc, fr, pitch=-12, width=12, depth=8, thickness=0.13, steps=8)
    blush = m.piece("CapBlush", PINK, material="Smooth")
    for side in (-1, 1):
        p, n = surface(fc, fr, side * 26, -2)
        oriented_ellipsoid(blush, tup(p), (0.5, 0.32, 0.1), normal=tup(n), rings=4, segments=10)
    stars_p = m.piece("Stars", SUN_GLOW, material="Neon")
    for k in range(8):
        a = 2 * math.pi * k / 8 + 0.4
        y = 3.0 + 7.5 * ((k * 3) % 8) / 7
        r = 6.0 + 0.8 * (k % 2)
        star(stars_p, (math.cos(a) * r, y, math.sin(a) * r), 0.8 - 0.1 * (k % 3), 0.22, normal=(math.cos(a), 0.0, math.sin(a)))
    joints["Stars"] = (0, 6.5, 0)
    for name, colour, seed in (("ConfettiA", HOT_PINK, 1), ("ConfettiB", SKY_BLUE, 2), ("ConfettiC", PURPLE, 3)):
        conf = m.piece(name, colour, material="Smooth")
        for k in range(8):
            a = 2 * math.pi * (k / 8) + seed * 0.8
            y = 2.5 + 9.0 * (((k * 5 + seed * 3) % 8) / 7)
            r = 3.6 + 3.0 * (((k * 3 + seed) % 5) / 4)
            tilt = (math.cos(a + seed), 0.6, math.sin(a * 2))
            plate(conf, [(-0.26, -0.14), (0.26, -0.14), (0.26, 0.14), (-0.26, 0.14)], (math.cos(a) * r, y, math.sin(a) * r), tilt, (0, 1, 0.3), 0.07)
        joints[name] = (0, 6.0, 0)
    m.pivot = (
        "ground centre of the impact (cloud rises from y = 0); smiling face toward -Z; ~12 tall x 12 wide at scale 1; "
        "groups tween in Base -> Stem -> Ring -> Cap(+CapFace/CapShine/CapBlush) -> Stars/Confetti*; " + joints_text(joints)
    )
    return m


BUILDERS = {
    "NukeT1": build_nuke_t1,
    "NukeT2": build_nuke_t2,
    "NukeT3": build_nuke_t3,
    "NukeT4": build_nuke_t4,
    "NukeT5": build_nuke_t5,
    "Interceptor": build_interceptor,
    "AATower1": build_aa_tower_1,
    "AATower2": build_aa_tower_2,
    "AATower3": build_aa_tower_3,
    "AATower4": build_aa_tower_4,
    "AATower5": build_aa_tower_5,
    "ShieldDome": build_shield_dome,
    "ConfettiCloud": build_confetti_cloud,
}
