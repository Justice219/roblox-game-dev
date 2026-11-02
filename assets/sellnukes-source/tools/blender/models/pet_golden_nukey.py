"""
pet_golden_nukey.py — the GOLDEN NUKEY pet (owner R78 retention pack, spec
docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md §5): a golden, sparkly CHIBI of the
lobby's Nukey mascot (hub_plaza.py `nukey_figure`, the waving fountain statue), the exclusive
Nuke Pass Season 1 premium tier-30 pet (PetConfig id `golden_nukey`, mesh key `SparkleNukey`).

Why a new mesh (not the older pets.py `GoldenNukey`): that Secret species is a plain gold nuke with
a crown and two atom rings; it does not read as the mascot. This one re-uses the statue's
silhouette and face so every kid recognises "Nukey" at pet size:

    statue (hub_plaza.nukey_figure)          chibi (this file)
    red nose cap + white shine               amber-gold cap + white shine (same upper-left oval)
    sunny yellow capsule body                gold body, squatter + rounder (chibi: radius / height
                                             0.34 instead of the statue's 0.21)
    big white eyes, pupils looking in,       the same face, eyes ~2x larger relative to the body
    brows, rosy cheeks, wide smile
    lime belt                                lime belt (Neon, pulses softly: PetAnim Glow token)
    white belly disc + black trefoil         the same badge under the belt
    4 toy-blue fins + nozzle foot            4 dark-gold fins + nozzle foot (it stands on them)
    left fist on the hip, right arm waving   the same pose (static: the pet HOPS, PetAnimConfig)
    -                                        "sparkly": a Neon sparkle ring with 4 riding stars +
                                             a little halo (Orbit group, spins), and white
                                             4-point glints on the gold (Smooth, never brighter)

Art contract (docs/pets-art.md §1-§2, same as pets.py / pets_moon.py):
    * ONE model, 9 single-colour pieces (<= 10 draw calls), <= 2,800 triangles.
    * Body / cap / fins / gloves `StudsSmall` (stud material, owner rule 2); face bits `Smooth`;
      belt + sparkles `Neon` (small accents only, owner R19).
    * ORIGIN = ground-contact centre (fin bottoms on y = 0 under the middle); FACES -Z; +X = its
      right-hand side; ~2.5 studs tall to the cap tip (a Mythic pet renders x1.24 in game).
    * Piece-name prefix = PetAnim group: `Orbit*` spins about the Orbit joint (pivot string);
      everything else is the rigid Body group (Body / Fins squash; Glow pulses). There is no Head
      group: Nukey's face IS the body, exactly like the older GoldenNukey (style Hop, PetAnimConfig).

Pieces:
    Body     gold capsule body + both arms (shoulders buried in the body)
    Nose     amber-gold rounded cap (the mascot's "red cap" in gold)
    Fins     dark-gold nozzle foot + 4 chunky fins
    Glow     lime Neon belt
    Gloves   white glove fist (left, on the hip) + open waving glove with thumb (right)
    Eyes     eye whites, pupil highlights, cap shine, belly disc, white star glints (Smooth)
    Face     pupils, brows, smile, belly trefoil (Smooth, soft black)
    Cheeks   rosy cheeks (Smooth)
    Orbit    Neon sparkle hoop at the waist + 4 riding stars + halo above the cap (spins about +Y)

Build / preview / ship (docs/pets-art.md §12):
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only SparkleNukey
    /opt/homebrew/bin/blender -b --python tools/blender/viewport_look.py -- OUT SparkleNukey tools/blender/models/pet_golden_nukey.py
    python3 tools/blender/upload_meshes.py --user-id 1586034782 --only SparkleNukey
    python3 tools/blender/sync_meshes.py
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.kit import trefoil
from snkit.shapes import cylinder, ellipsoid, prism, revolve

from models._critter_kit import (
    BLUSH,
    GOLD,
    GOLD_DARK,
    SNOW,
    SOFT_BLACK,
    orbit_ring,
    oriented_ellipsoid,
    star,
    tube,
    tup,
)
from models.pets import MAT, _done, _pet

KEY = "SparkleNukey"

# Golden palette (brand NUKEY_PALETTE, docs/brand.md, re-tinted gold; judged with viewport_look.py).
CAP_AMBER = (255, 150, 34)  # the mascot's red cap, in warm amber gold
BELT_LIME = (110, 255, 90)  # Neon belt (the brand lime)
SPARKLE = (255, 240, 150)  # Neon sparkle ring / stars / halo (pale gold, reads as "shiny")

# Body dimensions (studs). The statue is 18 x radius 3.8 at scale 1; the chibi is squat + round.
R = 0.78  # body radius
BODY_Y0 = 0.2  # body bottom (sits in the nozzle foot)
BODY_Y1 = 1.6  # body top = cap bottom
CAP_TOP = 2.34  # cap tip
BELT_Y = 0.66  # lime belt centre (low, so the face gets the space a chibi needs)
EYE_Y = 1.2  # eye centres
# Sparkle ring centre = Orbit joint. Waist height + a shallow tilt: the Orbit group SPINS about +Y,
# so the ring's high side sweeps past the front; at y 0.55 +- 0.24 it stays under the smile (0.9)
# and outside the fins (r 1.1) in every phase (first Studio pass at y 1.2 crossed the eyes).
ORBIT_C = (0.0, 0.55, 0.0)
RING_R = 1.22
RING_TILT = (-9.0, -7.0)  # degrees about X, then Z (_critter_kit.tilted_normal)


def _front_z(x: float, radius: float = R) -> float:
    """Front (-Z) surface of the round body at horizontal offset x (the face sits on it)."""
    return -math.sqrt(max(radius * radius - x * x, 0.0004))


def _point_on_body(x: float, y: float, out: float = 0.0) -> Vector:
    """A point on the body's front surface at (x, y), pushed `out` studs along the normal."""
    z = _front_z(x)
    n = Vector((x, 0.0, z)).normalized()
    return Vector((x, y, z)) + n * out


def _normal_at(x: float) -> Vector:
    """Outward horizontal normal of the round body at offset x (front half)."""
    return Vector((x, 0.0, _front_z(x))).normalized()


def _body(m):
    """Capsule body, amber cap, nozzle foot + 4 fins, lime belt. Returns the pieces dict."""
    body = m.piece("Body", GOLD, material=MAT)
    nose = m.piece("Nose", CAP_AMBER, material=MAT)
    fins = m.piece("Fins", GOLD_DARK, material=MAT)
    glow = m.piece("Glow", BELT_LIME, material="Neon")
    seg = 16
    # Chubby capsule: rounded bottom shoulder, near-straight sides, slight taper to the cap.
    revolve(
        body,
        [
            (0.0, BODY_Y0),
            (R * 0.66, BODY_Y0),
            (R * 0.92, BODY_Y0 + 0.08),
            (R, BODY_Y0 + 0.26),
            (R * 1.01, 0.95),
            (R * 0.99, 1.35),
            (R * 0.97, BODY_Y1),
            (0.0, BODY_Y1),
        ],
        segments=seg,
    )
    # Rounded cap (a little proud of the body so it reads as a hat, like the statue's red cap).
    revolve(
        nose,
        [
            (0.0, BODY_Y1 - 0.02),
            (R * 1.02, BODY_Y1 - 0.02),
            (R * 1.0, BODY_Y1 + 0.18),
            (R * 0.88, BODY_Y1 + 0.42),
            (R * 0.62, BODY_Y1 + 0.6),
            (R * 0.3, CAP_TOP - 0.03),
            (0.0, CAP_TOP),
        ],
        segments=seg,
    )
    # Lime belt: proud band (closed ring profile).
    revolve(
        glow,
        [(R * 0.97, BELT_Y - 0.1), (R * 1.07, BELT_Y - 0.07), (R * 1.07, BELT_Y + 0.07), (R * 0.97, BELT_Y + 0.1)],
        center=(0.0, 0.0, 0.0),
        segments=seg,
        closed=True,
    )
    # Nozzle foot (the toy stands on it) + 4 chunky diagonal fins (two read at the sides from the
    # front, like the statue).
    revolve(fins, [(0.0, 0.0), (R * 0.56, 0.0), (R * 0.46, 0.12), (R * 0.52, BODY_Y0 + 0.06), (0.0, BODY_Y0 + 0.06)], segments=14)
    fin_h = 0.62
    for i in range(4):
        a = 2 * math.pi * i / 4 + math.pi / 4
        dx, dz = math.cos(a), math.sin(a)
        r0, r1 = R * 0.62, R * 1.42
        outline = [
            (dx * r0, 0.0, dz * r0),
            (dx * r1, 0.0, dz * r1),
            (dx * r1 * 0.9, fin_h * 0.5, dz * r1 * 0.9),
            (dx * r0, fin_h * 1.12, dz * r0),
        ]
        prism(fins, outline, (-dz, 0.0, dx), 0.24)
    return {"body": body, "nose": nose, "fins": fins, "glow": glow}


def _face(m):
    """Big glossy eyes, pupils looking slightly in, brows, cheeks, wide smile, cap shine, badge."""
    whites = m.piece("Eyes", SNOW, material="Smooth")
    dark = m.piece("Face", SOFT_BLACK, material="Smooth")
    pink = m.piece("Cheeks", BLUSH, material="Smooth")
    for side in (-1, 1):
        ex = side * 0.27
        n = _normal_at(ex)
        c = _point_on_body(ex, EYE_Y, -0.04)
        oriented_ellipsoid(whites, tup(c), (0.2, 0.27, 0.1), normal=tup(n), rings=6, segments=12)
        # Pupils: lower + inward (the statue's friendly "looking at you" glance).
        px = side * 0.235
        pn = _normal_at(px)
        pc = _point_on_body(px, EYE_Y - 0.03, 0.035)
        oriented_ellipsoid(dark, tup(pc), (0.11, 0.155, 0.05), normal=tup(pn), rings=5, segments=10)
        # Highlight up-and-in on each pupil.
        hc = _point_on_body(px + side * 0.035, EYE_Y + 0.05, 0.075)
        oriented_ellipsoid(whites, tup(hc), (0.042, 0.05, 0.02), normal=tup(pn), rings=3, segments=6)
        # Brows: short chunky bars hugging the body above the eyes.
        a = _point_on_body(side * 0.12, EYE_Y + 0.33, 0.01)
        b = _point_on_body(side * 0.42, EYE_Y + 0.37, 0.01)
        tube(dark, [tup(a), tup(b)], 0.035, sides=5)
        # Rosy cheeks under the outer eye corners.
        cx = side * 0.5
        oriented_ellipsoid(pink, tup(_point_on_body(cx, EYE_Y - 0.25, -0.01)), (0.12, 0.075, 0.04), normal=tup(_normal_at(cx)), rings=4, segments=8)
    # Wide smile: a curved tube hugging the body between the eyes and the belt.
    path = []
    for i in range(9):
        t = -1.0 + i * 0.25
        x = 0.24 * t
        path.append(tup(_point_on_body(x, 0.9 + 0.07 * t * t, 0.015)))
    tube(dark, path, 0.033, sides=5)
    # Cap shine: white oval upper-left (as on the statue's cap).
    sx = -0.3
    sy = BODY_Y1 + 0.34
    cap_r = R * 0.9
    sz = -math.sqrt(max(cap_r * cap_r - sx * sx, 0.01))
    oriented_ellipsoid(whites, (sx, sy, sz), (0.09, 0.15, 0.03), normal=tup(Vector((sx, 0.35, sz)).normalized()), rings=4, segments=8)
    # Belly badge under the belt: white disc + soft-black trefoil.
    by = 0.38
    bn = _normal_at(0.0)
    oriented_ellipsoid(whites, tup(_point_on_body(0.0, by, -0.005)), (0.15, 0.15, 0.035), normal=tup(bn), rings=4, segments=12)
    trefoil(dark, tup(_point_on_body(0.0, by, 0.03)), 0.12, 0.02, normal=tup(bn))
    return whites, dark


def _arms(m, body):
    """Left fist on the hip, right arm waving (statue pose, scaled to the chibi; static)."""
    gloves = m.piece("Gloves", SNOW, material=MAT)
    # Left: shoulder buried in the body, elbow out, forearm back in to the hip.
    sh_l, el_l, wr_l = (-0.66, 1.0, 0.0), (-1.02, 0.78, 0.04), (-0.86, 0.56, -0.06)
    cylinder(body, sh_l, el_l, 0.12, segments=10)
    ellipsoid(body, el_l, (0.13, 0.13, 0.13), rings=4, segments=8)
    cylinder(body, el_l, wr_l, 0.11, segments=10)
    ellipsoid(gloves, (-0.82, 0.5, -0.08), (0.17, 0.16, 0.15), rings=5, segments=10)
    # Right: upper arm out, forearm up, cuff + open glove with a thumb, palm to the front.
    sh_r, el_r, wr_r = (0.66, 1.02, 0.0), (1.0, 1.2, -0.06), (1.08, 1.5, -0.1)
    cylinder(body, sh_r, el_r, 0.12, segments=10)
    ellipsoid(body, el_r, (0.125, 0.125, 0.125), rings=4, segments=8)
    cylinder(body, el_r, wr_r, 0.11, segments=10)
    d = (Vector(wr_r) - Vector(el_r)).normalized()
    w = Vector(wr_r)
    cylinder(gloves, tup(w - d * 0.03), tup(w + d * 0.08), 0.145, segments=10)
    g = w + d * 0.22
    oriented_ellipsoid(gloves, tup(g), (0.17, 0.2, 0.11), normal=(0.15, 0.0, -1.0), up=tup(d), rings=5, segments=10)
    oriented_ellipsoid(gloves, tup(g + Vector((-0.15, -0.05, -0.02))), (0.06, 0.09, 0.06), normal=(0.0, 0.0, -1.0), up=(-0.6, 1.0, 0.0), rings=4, segments=8)


def _sparkles(m, whites):
    """Neon sparkle hoop at the waist (one shallow ring: it spins, so a higher or second ring would
    sweep across the face) with 4 riding stars, a halo above the cap, and white glints on the gold."""
    orbit = m.piece("Orbit", SPARKLE, material="Neon")
    orbit_ring(orbit, ORBIT_C, RING_R, 0.035, tilt_x=RING_TILT[0], tilt_z=RING_TILT[1], segments=24, sides=4)
    # Stars riding the ring (same plane maths as orbit_ring: tilt about X then Z).
    ax, az = math.radians(RING_TILT[0]), math.radians(RING_TILT[1])
    ny = Vector((0.0, math.cos(ax), math.sin(ax)))
    n = Vector((ny.x * math.cos(az) - ny.y * math.sin(az), ny.x * math.sin(az) + ny.y * math.cos(az), ny.z)).normalized()
    s = Vector((1.0, 0.0, 0.0))
    s = (s - n * s.dot(n)).normalized()
    u = n.cross(s).normalized()
    for k in range(4):
        t = 2 * math.pi * (k + 0.5) / 4
        p = Vector(ORBIT_C) + s * (RING_R * math.cos(t)) + u * (RING_R * math.sin(t))
        out = (p - Vector(ORBIT_C)).normalized()
        star(orbit, tup(p), 0.21, 0.06, normal=tup(out), up=tup(n), inner_ratio=0.45)
    # Halo above the cap (rides with the ring: one Orbit group).
    orbit_ring(orbit, (0.0, CAP_TOP + 0.2, 0.0), 0.3, 0.035, tilt_x=-12.0, segments=18, sides=4)
    m.joints["Orbit"] = ORBIT_C
    # White star glints on the gold (Smooth white, part of the Eyes piece: no extra draw call).
    for x, y, size in ((-0.56, 1.42, 0.1), (0.6, 0.4, 0.09), (0.62, 1.4, 0.08)):
        p = _point_on_body(x, y, 0.012)
        star(whites, tup(p), size, 0.02, normal=tup(_normal_at(x)), inner_ratio=0.3)
    p = Vector((0.36, BODY_Y1 + 0.48, -0.42))
    star(whites, tup(p), 0.07, 0.02, normal=tup(Vector((0.4, 0.5, -0.75)).normalized()), inner_ratio=0.3)


def build_sparkle_nukey():
    """Golden Nukey: the lobby mascot as a golden, sparkly chibi pet (Mythic, exclusive)."""
    m = _pet(KEY, "Mythic")
    parts = _body(m)
    whites, _dark = _face(m)
    _arms(m, parts["body"])
    _sparkles(m, whites)
    return _done(m)


BUILDERS = {
    KEY: build_sparkle_nukey,
}
