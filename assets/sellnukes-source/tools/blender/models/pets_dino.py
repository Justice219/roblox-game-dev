"""
pets_dino.py — the World 2 "Dino Valley" pet roster: chunky, round, big-eyed toy dinosaurs
(spec 2026-10-31-world2-design.md §8 / §16, owner R57). Same art contract as pets.py (B8f):

    * ONE Blender model per pet, <= 10 single-colour pieces (<= 10 draw calls), <= 2,800 triangles.
    * Bodies `StudsSmall`, faces / eyes `Smooth`, glowing bits `Neon` (small accents only: R19).
    * ORIGIN = ground-contact centre (y = 0 under the pet's middle); the pet FACES -Z; +X is its
      right-hand side; 1.8-2.6 studs tall (hip height of an R15 avatar). Flyers get `hover`.
    * Piece-name prefix = PetAnim animation group (docs/pets-art.md §1, Client/Pets/PetAnim):
        Head*            neck / head / face / crest / horns / frill / goggles -> joint "Head"
        Tail*            tail + its club / spikes / tuft                    -> joint "Tail"
        WingL* / WingR*  ptero wings + their Neon veins                     -> joints "WingL" / "WingR"
        Orbit*           Neon atom rings (Rare+)                           -> joint "Orbit" (spins)
        anything else    the rigid Body (Body / Belly / Spikes squash; Glow* pulses, R19-safe)
      Joints ship in the pivot string (`joints Head@(x,y,z) ...`, pets._done) and every animated
      group is buried in its host at the joint, so a nod / wag / flap never opens a gap.
    * PetAnim derives the style: hover + WingL/WingR -> Fly (the two pteros); everything else Walk.

Kid-friendly (spec §2): every dino is round, smiling and soft — no teeth, no claws shown, horns /
spikes / tail clubs end in round balls. Lava is candy-orange glow; "Supernova" is a star sail.

Roster (key — display name — rarity — egg — hover):
    AtomRaptor      Atom Raptor       Uncommon   Dino Egg      0    teal biped, orange feather crest,
                                                                    holds a glowing atom pebble
    GlowStego       Glow Stego        Rare       Dino Egg      0    fern-green stego, Neon back plates
    FissionTrike    Fission Trike     Epic       Dino Egg      0    periwinkle trike, violet frill with
                                                                    a Neon rim, round-tipped horns
    PocketBronto    Pocket Bronto     Legendary  Dino Egg      0    pink long-neck, gold crown, glow spots
    EmberAnkylo     Ember Ankylo      Rare       Volcano Egg   0    warm-orange ankylo, lava-yellow armour
                                                                    bumps, red-hot glints, round tail club
    MagmaPtero      Magma Ptero       Epic       Volcano Egg   0.9  red ptero, Neon lava-vein wings
    LavaPara        Lava Para         Legendary  Volcano Egg   0    magenta parasaur, Neon lava stripes,
                                                                    gold head crest, two lava rings
    SupernovaSpino  Supernova Spino   Mythic     Volcano Egg   0    violet spino, Neon star sail, gold
                                                                    star, starry spots, two rings
    TimePtero       Time Ptero        Epic       Time Traveler 1.0  teal ptero, brass goggles, clock-face
                                                 Pack (fixed)       belly with Neon hands

Build / preview / ship (docs/pets-art.md header has the full recipe):
    KEYS=AtomRaptor,GlowStego,FissionTrike,PocketBronto,EmberAnkylo,MagmaPtero,LavaPara,SupernovaSpino,TimePtero
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only $KEYS
    python3 tools/blender/contact_sheet.py --only $KEYS
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import CREAM, GLOW_GREEN, TOY_RED
from snkit.shapes import cylinder, ellipsoid

from models._critter_kit import (
    GOLD,
    SKY_GLOW,
    SUN_GLOW,
    catmull,
    circle_points,
    crown,
    frame,
    oriented_ellipsoid,
    plate,
    smile,
    star,
    star_outline,
    surface,
    tube,
    tup,
    v3,
)
from models.pets import MAT, _blob, _done, _face, _legs, _orbit, _overside, _pet, _spots, _tail, _wing_plate

# Dino Valley palette (spec §2: fern green / sand / amber / bone cream / candy lava orange).
RAPTOR_TEAL = (64, 200, 210)
CREST_ORANGE = (255, 150, 60)
STEGO_FERN = (104, 196, 96)
PLATE_AMBER = (255, 190, 60)
BELLY_SAND = (250, 226, 150)
TRIKE_PERI = (126, 146, 250)
FRILL_VIOLET = (150, 110, 240)
BRONTO_PINK = (236, 150, 214)
ANKYLO_ORANGE = (255, 138, 44)
ARMOUR_LAVA = (255, 206, 58)  # lava-yellow armour plates + tail club (vividness pass, R47)
EMBER_GLOW = (255, 72, 48)  # red-hot ember glints (small Neon accents, R19)
ANKYLO_RING = (255, 170, 60)
MAGMA_RED = (232, 84, 64)
MAGMA_WING = (255, 128, 64)
LAVA_GLOW = (255, 196, 70)
PARA_MAGENTA = (232, 66, 168)  # saturated magenta (vividness pass, R47)
PEACH = (255, 214, 150)
BILL_CREAM = (255, 218, 170)
LAVA_ORANGE = (255, 130, 40)
SPINO_VIOLET = (142, 74, 255)  # electric violet (vividness pass, R47)
SPINO_BELLY = (214, 190, 255)
SAIL_PINK = (255, 96, 214)
TIME_TEAL = (40, 190, 180)
TIME_WING = (120, 220, 232)
BRASS = (214, 160, 60)
BEAK_GOLD = (255, 200, 70)


# ------------------------------------------------------------------------------------------------
# Dino parts (append into pieces the caller picked, so colours stay grouped)
# ------------------------------------------------------------------------------------------------


def _biped_legs(body, hip_x, hip_y, hip_z, thigh, foot, foot_z, rings=6, segments=10):
    """
    Chunky toy dino legs for bipeds: a round thigh buried in the body underside and a long rounded
    foot on the ground (y = 0) that the thigh overlaps, so nothing floats or gaps.
    """
    for sx in (-1, 1):
        ellipsoid(body, (sx * hip_x, hip_y, hip_z), thigh, rings=rings, segments=segments)
        ellipsoid(body, (sx * (hip_x + 0.02), foot[1], foot_z), foot, rings=5, segments=segments)


def _tiny_arms(body, shoulder, hand, radius=0.065):
    """Two stubby T-rex-style arms (tube + round mitten), mirrored across X. Kid-cute, no claws."""
    for sx in (-1, 1):
        s = (sx * shoulder[0], shoulder[1], shoulder[2])
        h = (sx * hand[0], hand[1], hand[2])
        tube(body, [s, h], radius, sides=6)
        r = radius * 1.3
        ellipsoid(body, h, (r, r, r), rings=4, segments=8)


def _nostrils(face, center, radii, yaw=16.0, pitch=34.0, size=0.034):
    """Two little dark nostril dots on the top-front of a snout."""
    for sx in (-1, 1):
        p, n = surface(center, radii, sx * yaw, pitch)
        oriented_ellipsoid(face, tup(p), (size, size * 0.85, size * 0.5), normal=tup(n), rings=3, segments=6)


def _belly_patch(belly, center, radii, pitch, size, sink=0.1, yaw=0.0):
    """Lighter belly / chest patch half-buried in the body front (squashes with the body)."""
    p, n = surface(center, radii, yaw, pitch)
    oriented_ellipsoid(belly, tup(p - n * sink), size, normal=tup(n), rings=6, segments=10)


def _round_spike(piece, base, tip, r0, ball=None):
    """A soft cone ending in a round ball (horns, tail spikes): pointy silhouette, safe tip."""
    cylinder(piece, base, tip, r0, segments=7, radius_b=r0 * 0.4)
    b = ball if ball is not None else r0 * 0.55
    ellipsoid(piece, tip, (b, b, b), rings=4, segments=7)


def _feather_crest(piece, origins):
    """
    Feather crest, each feather (origin, lean_deg_back, height, width, splay_deg).
    splay 0  -> a mohawk feather in the YZ plane (reads from the side), tipped back by `lean`.
    splay != 0 -> a FRONT-facing feather (plane ~XY, so it reads from the front) tipped outward
                  by `splay` degrees (+X for positive) and back by `lean`.
    Mixing both gives a crest that reads from every camera angle.
    """
    for origin, lean, h, w, splay in origins:
        a, b = math.radians(lean), math.radians(splay)
        outline = [(-w, 0), (w, 0), (w * 0.65, h * 0.7), (0, h), (-w * 0.65, h * 0.7)]
        if splay == 0:
            plate(piece, outline, origin, (1, 0, 0), (0, math.cos(a), math.sin(a)), 0.07)
            continue
        up = Vector((math.sin(b), math.cos(b) * math.cos(a), math.cos(b) * math.sin(a))).normalized()
        normal = Vector((0.0, 0.0, -1.0))
        normal = (normal - up * normal.dot(up)).normalized()
        plate(piece, outline, origin, tup(normal), tup(up), 0.07)


def _ptero_head_crest(head, hc, hr, length=0.62, width=0.15):
    """Backward-sweeping ptero head crest (in the Head piece's colour), base buried in the skull."""
    p, n = surface(hc, hr, 180, 42)
    origin = p - n * 0.12
    outline = [(-width, 0), (width, 0), (width * 0.55, length * 0.7), (0, length), (-width * 0.45, length * 0.62)]
    # Plate in the YZ plane; local "up" points back-and-up so the crest sweeps behind the head.
    plate(head, outline, tup(origin), (1, 0, 0), (0, 0.5, 1), 0.08)


# Membrane wing outline (span OUTWARD from the shoulder, up): straight leading edge to a high tip,
# scalloped trailing edge back to the body — the classic friendly ptero kite shape.
PTERO_WING = [(-0.06, 0.06), (0.3, 0.2), (0.7, 0.34), (1.12, 0.46), (1.0, 0.25), (0.82, 0.12), (0.62, -0.02),
              (0.42, -0.06), (0.22, -0.14), (0.04, -0.14)]


def _wing_axes(side, back, lift):
    """(span axis a, up axis u) of a wing plate exactly as pets._wing_plate builds it."""
    a = Vector((side, lift, back)).normalized()
    u = Vector((0.0, 1.0, 0.0))
    u = (u - a * u.dot(a)).normalized()
    return a, u


def _ptero_wings(m, color, shoulder, back=0.35, lift=0.2, glow_color=None, veins=()):
    """
    WingL / WingR membrane plates at mirrored shoulders (+ optional Neon vein tubes per wing as
    WingLGlow / WingRGlow, same animation group as their wing). Vein tubes sit on the wing
    mid-plane slightly thicker than the plate, so they read as glowing ridges from both sides.
    Writes the WingL / WingR joints.
    """
    for side, name in ((-1, "WingL"), (1, "WingR")):
        wing = m.piece(name, color, material=MAT)
        s = (side * shoulder[0], shoulder[1], shoulder[2])
        _wing_plate(wing, PTERO_WING, s, side, back=back, lift=lift, thick=0.08)
        m.joints[name] = s
        if glow_color is not None and veins:
            glow = m.piece(name + "Glow", glow_color, material="Neon")
            a, u = _wing_axes(side, back, lift)
            o = v3(s)
            for path in veins:
                tube(glow, [tup(o + a * x + u * y) for x, y in path], 0.062, sides=5)


# ------------------------------------------------------------------------------------------------
# DINO EGG (area 2): Uncommon / Rare / Epic / Legendary
# ------------------------------------------------------------------------------------------------


def build_atom_raptor():
    """Atom Raptor: teal chibi raptor, orange feather crest + tail tuft, hugs a glowing atom pebble."""
    m = _pet("AtomRaptor", "Uncommon")
    body = m.piece("Body", RAPTOR_TEAL, material=MAT)
    bc, br_ = (0, 0.88, 0.12), (0.44, 0.52, 0.5)
    _blob(body, bc, br_)
    _biped_legs(body, 0.26, 0.42, 0.22, (0.2, 0.25, 0.25), (0.16, 0.1, 0.28), 0.0)
    _tiny_arms(body, (0.3, 1.02, -0.2), (0.19, 0.86, -0.5))
    belly = m.piece("Belly", CREAM, material=MAT)
    _belly_patch(belly, bc, br_, -8, (0.32, 0.4, 0.13))
    head = m.piece("Head", RAPTOR_TEAL, material=MAT)
    hc, hr = (0, 1.6, -0.3), (0.48, 0.42, 0.48)
    _blob(head, hc, hr, rings=10, segments=16)
    snout_c, snout_r = (0, 1.49, -0.7), (0.3, 0.22, 0.26)
    _blob(head, snout_c, snout_r, rings=6, segments=12)
    m.joints["Head"] = (0, 1.25, -0.2)
    face, _ = _face(m, hc, hr, eye_yaw=30, eye_pitch=16, eye_size=0.13, mouth=False)
    smile(face, snout_c, snout_r, pitch=-14, width=34, depth=7, thickness=0.03, steps=8)
    _nostrils(face, snout_c, snout_r)
    crest = m.piece("HeadCrest", CREST_ORANGE, material=MAT)
    _feather_crest(crest, (((0, 1.96, -0.36), 14, 0.46, 0.1, 0), ((-0.14, 1.9, -0.3), 18, 0.32, 0.09, -34),
                           ((0.14, 1.9, -0.3), 18, 0.32, 0.09, 34), ((0, 1.92, -0.14), 56, 0.3, 0.08, 0)))
    tail = m.piece("Tail", RAPTOR_TEAL, material=MAT)
    pts = _tail(tail, [(0, 0.82, 0.48), (0, 0.85, 0.9), (0, 0.98, 1.26), (0, 1.08, 1.5)], 0.25, 0.08, tip=False)
    m.joints["Tail"] = (0, 0.82, 0.52)
    tuft = m.piece("TailTuft", CREST_ORANGE, material=MAT)
    end = v3(pts[-1])
    for k, yaw in enumerate((-28, 0, 28)):  # feather tuft fanning off the tail tip
        a = math.radians(yaw)
        plate(tuft, [(-0.07, 0), (0.07, 0), (0.04, 0.24), (0, 0.32), (-0.04, 0.24)], tup(end - Vector((0, 0, 0.06))),
              (math.cos(a), 0, math.sin(a)), (math.sin(a) * 0.6, 0.35, 1.0), 0.06)
    for i in (3, 7):  # two orange stripes around the tail
        c = v3(pts[i])
        t = (v3(pts[i + 1]) - v3(pts[i - 1])).normalized()
        r = 0.25 + (0.08 - 0.25) * (i / (len(pts) - 1)) + 0.012
        tube(tuft, circle_points(tup(c), r, normal=tup(t), segments=10), 0.035, sides=4, closed=True)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    _spots(glow, bc, br_, [(150, 35), (-150, 35), (180, 55, 0.8), (125, 12, 0.7), (-125, 12, 0.7)], size=0.09)
    pebble = (0, 0.84, -0.6)
    ellipsoid(glow, pebble, (0.14, 0.15, 0.14), rings=6, segments=10)  # the glowing atom pebble it hugs
    return _done(m)


def build_glow_stego():
    """Glow Stego: round fern-green stegosaurus, Neon amber back plates, soft ball-tipped tail spikes."""
    m = _pet("GlowStego", "Rare")
    body = m.piece("Body", STEGO_FERN, material=MAT)
    bc, br_ = (0, 0.78, 0.15), (0.6, 0.5, 0.76)
    _blob(body, bc, br_)
    _legs(body, bc, br_, spread=0.55, front=0.55, back=0.55, leg_r=0.2)
    belly = m.piece("Belly", BELLY_SAND, material=MAT)
    _belly_patch(belly, bc, br_, -22, (0.38, 0.3, 0.14))
    head = m.piece("Head", STEGO_FERN, material=MAT)
    hc, hr = (0, 1.0, -0.8), (0.44, 0.38, 0.42)
    _blob(head, hc, hr, rings=10, segments=16)
    snout_c, snout_r = (0, 0.88, -1.08), (0.27, 0.19, 0.2)
    _blob(head, snout_c, snout_r, rings=6, segments=12)
    m.joints["Head"] = (0, 0.9, -0.5)
    face, _ = _face(m, hc, hr, eye_yaw=34, eye_pitch=14, eye_size=0.12, mouth=False)
    smile(face, snout_c, snout_r, pitch=-10, width=36, depth=7, thickness=0.028, steps=8)
    _nostrils(face, snout_c, snout_r, yaw=18, pitch=40, size=0.03)
    glow = m.piece("Glow", PLATE_AMBER, material="Neon")
    for z, h, w, x in ((-0.34, 0.36, 0.17, -0.08), (-0.08, 0.52, 0.22, 0.08), (0.2, 0.6, 0.25, -0.08),
                       (0.47, 0.5, 0.21, 0.08), (0.72, 0.34, 0.16, -0.08)):
        y = _overside(bc, br_, x, z) - 0.1
        lean = math.radians(8) * (1 if x > 0 else -1)
        outline = [(-w, 0), (w, 0), (w * 0.95, h * 0.45), (w * 0.55, h * 0.85), (0, h), (-w * 0.55, h * 0.85), (-w * 0.95, h * 0.45)]
        plate(glow, outline, (x, y, z), (math.cos(lean), -math.sin(lean), 0), (math.sin(lean), math.cos(lean), 0), 0.08)
    tail = m.piece("Tail", STEGO_FERN, material=MAT)
    pts = _tail(tail, [(0, 0.72, 0.74), (0, 0.62, 1.1), (0, 0.62, 1.42), (0, 0.7, 1.62)], 0.26, 0.08)
    m.joints["Tail"] = (0, 0.72, 0.78)
    spikes = m.piece("TailSpikes", CREAM, material=MAT)
    for idx, sx in ((-4, -1), (-4, 1), (-2, -1), (-2, 1)):
        c = v3(pts[idx])
        d = Vector((sx * 0.9, 0.38, 0.42)).normalized()
        _round_spike(spikes, tup(c), tup(c + d * 0.34), 0.075, ball=0.06)
    _orbit(m, (0, 1.0, 0.15), 1.15, rings=((-22.0, -18.0),))
    return _done(m)


def _frill_outline(radius, scallops=11, start=-18.0, end=198.0, chord=-0.16):
    """Half-disc trike frill with round scallops along its arc; flat chord at local y = chord."""
    pts = [(radius * math.cos(math.radians(start)), chord)]
    steps = scallops * 3
    for i in range(steps + 1):
        a = math.radians(start + (end - start) * i / steps)
        bump = 1.0 + 0.07 * math.cos(math.pi * 2 * (i % 3) / 3)
        y = max(radius * bump * math.sin(a), chord)
        pts.append((radius * bump * math.cos(a), y))
    pts.append((radius * math.cos(math.radians(end)), chord))
    return pts


def build_fission_trike():
    """Fission Trike: periwinkle triceratops, violet frill with a Neon rim + atom dots, ball-tipped horns."""
    m = _pet("FissionTrike", "Epic")
    body = m.piece("Body", TRIKE_PERI, material=MAT)
    bc, br_ = (0, 0.75, 0.2), (0.6, 0.52, 0.72)
    _blob(body, bc, br_)
    _legs(body, bc, br_, spread=0.55, front=0.55, back=0.55, leg_r=0.21)
    belly = m.piece("Belly", CREAM, material=MAT)
    _belly_patch(belly, bc, br_, -20, (0.36, 0.3, 0.14))
    head = m.piece("Head", TRIKE_PERI, material=MAT)
    hc, hr = (0, 1.02, -0.66), (0.48, 0.42, 0.46)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 0.95, -0.35)
    face, _ = _face(m, hc, hr, eye_yaw=32, eye_pitch=8, eye_size=0.13, mouth_pitch=-26, mouth_w=18)
    horns = m.piece("HeadHorns", CREAM, material=MAT)
    p, n = surface(hc, hr, 0, -22)  # rounded parrot beak
    _round_spike(horns, tup(p - n * 0.12), tup(p + n * 0.18 + Vector((0, -0.05, 0))), 0.15, ball=0.08)
    p, n = surface(hc, hr, 0, 16)  # little nose horn
    _round_spike(horns, tup(p - n * 0.06), tup(p + Vector((0, 0.2, -0.12))), 0.09, ball=0.055)
    for side in (-1, 1):  # brow horns
        p, n = surface(hc, hr, side * 26, 40)
        _round_spike(horns, tup(p - n * 0.06), tup(p + Vector((side * 0.07, 0.38, -0.2))), 0.11, ball=0.07)
    frill = m.piece("HeadFrill", FRILL_VIOLET, material=MAT)
    f_origin = Vector((0, 1.26, -0.3))
    f_normal = Vector((0, 0.38, -1)).normalized()
    f_up = Vector((0, 1, 0.38)).normalized()
    outline = _frill_outline(0.62)
    plate(frill, outline, tup(f_origin), tup(f_normal), tup(f_up), 0.1)
    rim = m.piece("HeadGlow", GLOW_GREEN, material="Neon")
    s_, u_, n_ = frame(f_normal, f_up)
    arc = [p for p in outline[1:-1] if p[1] > -0.1]
    tube(rim, [tup(f_origin + s_ * x + u_ * y) for x, y in arc], 0.06, sides=5)
    for x, y in ((-0.3, 0.26), (0.0, 0.4), (0.3, 0.26)):  # three glowing atom dots on the frill face
        oriented_ellipsoid(rim, tup(f_origin + s_ * x + u_ * y + n_ * 0.05), (0.07, 0.07, 0.03), normal=tup(n_), rings=4, segments=8)
    tail = m.piece("Tail", TRIKE_PERI, material=MAT)
    _tail(tail, [(0, 0.68, 0.8), (0, 0.58, 1.12), (0, 0.52, 1.36)], 0.24, 0.07)
    m.joints["Tail"] = (0, 0.68, 0.82)
    _orbit(m, (0, 0.95, 0.2), 1.14, rings=((-20.0, -16.0),), electrons=2)
    return _done(m)


def build_pocket_bronto():
    """Pocket Bronto: pink long-neck with a gold toy crown, glowing back spots and a curly tail."""
    m = _pet("PocketBronto", "Legendary")
    body = m.piece("Body", BRONTO_PINK, material=MAT)
    bc, br_ = (0, 0.72, 0.28), (0.6, 0.5, 0.72)
    _blob(body, bc, br_)
    _legs(body, bc, br_, spread=0.55, front=0.55, back=0.55, leg_r=0.22)
    belly = m.piece("Belly", CREAM, material=MAT)
    _belly_patch(belly, bc, br_, -18, (0.38, 0.3, 0.14))
    head = m.piece("Head", BRONTO_PINK, material=MAT)
    neck = catmull([(0, 0.92, -0.18), (0, 1.3, -0.46), (0, 1.66, -0.6), (0, 1.84, -0.64)], per=3)
    count = len(neck)
    tube(head, neck, 0.24, sides=7, radii=[0.25 - 0.08 * (i / (count - 1)) for i in range(count)])
    hc, hr = (0, 1.92, -0.74), (0.36, 0.3, 0.4)
    _blob(head, hc, hr, rings=9, segments=12)
    m.joints["Head"] = (0, 1.0, -0.26)
    _face(m, hc, hr, eye_yaw=36, eye_pitch=8, eye_size=0.11, mouth_pitch=-20, mouth_w=24)
    band = m.piece("HeadCrown", GOLD, material=MAT)
    gem = m.piece("HeadGem", TOY_RED, material="Smooth")
    crown(band, gem, (0, hc[1] + hr[1] - 0.08, hc[2] + 0.04), 0.19, 0.24, points=4, segments=12)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    _spots(glow, bc, br_, [(148, 38), (-148, 38), (118, 14, 0.8), (-118, 14, 0.8)], size=0.14)
    tail = m.piece("Tail", BRONTO_PINK, material=MAT)
    _tail(tail, [(0, 0.68, 0.84), (0.05, 0.55, 1.24), (0.2, 0.42, 1.54), (0.42, 0.36, 1.7)], 0.26, 0.07, per=3)
    m.joints["Tail"] = (0, 0.68, 0.88)
    _orbit(m, (0, 0.95, 0.25), 1.15, color=SUN_GLOW, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


# ------------------------------------------------------------------------------------------------
# VOLCANO EGG (area 5): Rare / Epic / Legendary / Mythic
# ------------------------------------------------------------------------------------------------


def build_ember_ankylo():
    """Ember Ankylo: wide warm-orange ankylosaur, lava-yellow armour bumps, red-hot glints, round tail club."""
    m = _pet("EmberAnkylo", "Rare")
    body = m.piece("Body", ANKYLO_ORANGE, material=MAT)
    bc, br_ = (0, 0.68, 0.18), (0.72, 0.5, 0.82)
    _blob(body, bc, br_)
    _legs(body, bc, br_, spread=0.6, front=0.55, back=0.55, leg_r=0.21)
    spikes = m.piece("Spikes", ARMOUR_LAVA, material=MAT)
    rows = ((68, 0.16, (30, 90, 150, 210, 270, 330)), (40, 0.15, (0, 50, 100, 140, 180, 220, 260, 310)),
            (16, 0.13, (60, 100, 140, 180, 220, 260, 300)))
    for pitch, size, yaws in rows:
        for yaw in yaws:
            p, n = surface(bc, br_, yaw, pitch)
            oriented_ellipsoid(spikes, tup(p - n * 0.02), (size, size, size * 0.66), normal=tup(n), rings=3, segments=6)
    p, n = surface(bc, br_, 0, 90)
    oriented_ellipsoid(spikes, tup(p - n * 0.02), (0.17, 0.17, 0.11), normal=tup(n), rings=3, segments=6)
    head = m.piece("Head", ANKYLO_ORANGE, material=MAT)
    hc, hr = (0, 0.82, -0.86), (0.46, 0.38, 0.4)
    _blob(head, hc, hr, rings=10, segments=16)
    for side in (-1, 1):  # round cheek knobs
        p, n = surface(hc, hr, side * 72, 6)
        ellipsoid(head, tup(p), (0.1, 0.1, 0.1), rings=3, segments=6)
    m.joints["Head"] = (0, 0.76, -0.52)
    _face(m, hc, hr, eye_yaw=30, eye_pitch=14, eye_size=0.12, mouth_pitch=-20, mouth_w=24)
    glow = m.piece("Glow", EMBER_GLOW, material="Neon")
    for yaw, pitch in ((60, 54), (-60, 54), (180, 54), (25, 28), (-25, 28), (120, 28), (-120, 28)):
        p, n = surface(bc, br_, yaw, pitch)
        oriented_ellipsoid(glow, tup(p - n * 0.01), (0.07, 0.07, 0.04), normal=tup(n), rings=3, segments=6)
    tail = m.piece("Tail", ANKYLO_ORANGE, material=MAT)
    _tail(tail, [(0, 0.58, 0.88), (0, 0.48, 1.22), (0, 0.44, 1.5)], 0.22, 0.1, tip=False)
    m.joints["Tail"] = (0, 0.58, 0.92)
    club = m.piece("TailClub", ARMOUR_LAVA, material=MAT)
    ellipsoid(club, (0, 0.44, 1.62), (0.24, 0.17, 0.2), rings=6, segments=10)
    for sx in (-1, 1):
        ellipsoid(club, (sx * 0.2, 0.44, 1.62), (0.13, 0.13, 0.14), rings=4, segments=8)
    tglow = m.piece("TailGlow", EMBER_GLOW, material="Neon")
    for sx in (-1, 1):
        oriented_ellipsoid(tglow, (sx * 0.31, 0.46, 1.62), (0.06, 0.06, 0.03), normal=(sx, 0.2, 0), rings=3, segments=7)
    _orbit(m, (0, 0.85, 0.2), 1.22, color=ANKYLO_RING, rings=((-20.0, -14.0),))
    return _done(m)


def build_magma_ptero():
    """Magma Ptero: chubby red pterodactyl, golden rounded beak, Neon lava veins on its wings."""
    m = _pet("MagmaPtero", "Epic", hover=0.9)
    body = m.piece("Body", MAGMA_RED, material=MAT)
    bc, br_ = (0, 0.72, 0.05), (0.44, 0.5, 0.48)
    _blob(body, bc, br_)
    for sx in (-1, 1):  # stubby feet (rounded, no talons) + a little tail point
        tube(body, [(sx * 0.18, 0.32, 0.1), (sx * 0.2, 0.08, 0.0)], 0.06, sides=6)
        ellipsoid(body, (sx * 0.2, 0.05, -0.06), (0.09, 0.05, 0.13), rings=4, segments=8)
    tube(body, [(0, 0.55, 0.45), (0, 0.42, 0.78)], 0.09, sides=6, radii=[0.1, 0.03])
    glow = m.piece("Glow", LAVA_GLOW, material="Neon")
    p, n = surface(bc, br_, 0, -6)
    oriented_ellipsoid(glow, tup(p - n * 0.07), (0.24, 0.3, 0.1), normal=tup(n), rings=6, segments=10)
    head = m.piece("Head", MAGMA_RED, material=MAT)
    hc, hr = (0, 1.36, -0.2), (0.42, 0.4, 0.42)
    _blob(head, hc, hr, rings=10, segments=16)
    _ptero_head_crest(head, hc, hr)
    m.joints["Head"] = (0, 1.02, -0.1)
    _face(m, hc, hr, eye_yaw=34, eye_pitch=16, eye_size=0.13, mouth=False)
    beak = m.piece("HeadBeak", BEAK_GOLD, material=MAT)
    p, n = surface(hc, hr, 0, -12)
    _round_spike(beak, tup(p - n * 0.12), tup(p + n * 0.36 + Vector((0, -0.06, 0))), 0.14, ball=0.065)
    veins = (((0.08, 0.0), (0.4, -0.02), (0.62, -0.01)), ((0.1, 0.06), (0.5, 0.14), (0.84, 0.13)),
             ((0.12, 0.12), (0.6, 0.28), (1.02, 0.36)))
    _ptero_wings(m, MAGMA_WING, (0.36, 0.95, 0.0), glow_color=LAVA_GLOW, veins=veins)
    return _done(m)


def build_lava_para():
    """Lava Para: magenta parasaurolophus, Neon lava stripes, peach duck-bill, gold tube crest."""
    m = _pet("LavaPara", "Legendary")
    body = m.piece("Body", PARA_MAGENTA, material=MAT)
    bc, br_ = (0, 0.9, 0.15), (0.52, 0.6, 0.56)
    _blob(body, bc, br_)
    _biped_legs(body, 0.3, 0.44, 0.25, (0.22, 0.27, 0.28), (0.18, 0.1, 0.3), 0.02, rings=5, segments=9)
    _tiny_arms(body, (0.34, 1.06, -0.22), (0.3, 0.86, -0.5), radius=0.07)
    belly = m.piece("Belly", PEACH, material=MAT)
    _belly_patch(belly, bc, br_, -6, (0.36, 0.46, 0.14))
    head = m.piece("Head", PARA_MAGENTA, material=MAT)
    hc, hr = (0, 1.72, -0.35), (0.44, 0.4, 0.46)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 1.32, -0.2)
    face, _ = _face(m, hc, hr, eye_yaw=32, eye_pitch=18, eye_size=0.13, mouth=False)
    bill = m.piece("HeadBill", BILL_CREAM, material=MAT)
    bill_c, bill_r = (0, 1.58, -0.8), (0.3, 0.15, 0.3)
    _blob(bill, bill_c, bill_r, rings=6, segments=12)
    smile(face, bill_c, bill_r, pitch=-6, width=40, depth=8, thickness=0.03, steps=6)
    _nostrils(face, bill_c, bill_r, yaw=20, pitch=58, size=0.03)
    crest = m.piece("HeadCrest", GOLD, material=MAT)
    path = catmull([(0, 1.94, -0.5), (0, 2.14, -0.22), (0, 2.24, 0.12), (0, 2.2, 0.42)], per=3)
    tube(crest, path, 0.12, sides=7, radii=[0.12 - 0.03 * (i / (len(path) - 1)) for i in range(len(path))])
    ellipsoid(crest, path[-1], (0.1, 0.1, 0.1), rings=4, segments=7)
    glow = m.piece("Glow", LAVA_ORANGE, material="Neon")
    for side in (-1, 1):  # gentle lava stripes down the back sides
        for yaw in (112, 142, 168):
            stripe = []
            for k in range(4):
                pitch = 64 - k * 21
                p, n = surface(bc, br_, side * (yaw + 5 * math.sin(k * 1.4)), pitch)
                stripe.append(tup(p + n * 0.012))
            tube(glow, stripe, 0.05, sides=4)
    tail = m.piece("Tail", PARA_MAGENTA, material=MAT)
    _tail(tail, [(0, 0.86, 0.55), (0, 0.78, 0.95), (0, 0.8, 1.3), (0, 0.9, 1.55)], 0.27, 0.07, per=3)
    m.joints["Tail"] = (0, 0.86, 0.58)
    _orbit(m, (0, 1.15, 0.15), 1.14, color=LAVA_ORANGE, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


def build_supernova_spino():
    """Supernova Spino: violet spinosaurus, Neon pink star sail, gold star, starry spots, two rings."""
    m = _pet("SupernovaSpino", "Mythic")
    body = m.piece("Body", SPINO_VIOLET, material=MAT)
    bc, br_ = (0, 0.9, 0.15), (0.5, 0.6, 0.56)
    _blob(body, bc, br_)
    _biped_legs(body, 0.28, 0.44, 0.25, (0.21, 0.27, 0.27), (0.17, 0.1, 0.29), 0.02)
    _tiny_arms(body, (0.32, 1.06, -0.2), (0.26, 0.88, -0.48), radius=0.068)
    belly = m.piece("Belly", SPINO_BELLY, material=MAT)
    _belly_patch(belly, bc, br_, -6, (0.34, 0.46, 0.14))
    head = m.piece("Head", SPINO_VIOLET, material=MAT)
    hc, hr = (0, 1.68, -0.38), (0.42, 0.38, 0.44)
    _blob(head, hc, hr, rings=10, segments=16)
    snout_c, snout_r = (0, 1.56, -0.84), (0.25, 0.18, 0.3)
    _blob(head, snout_c, snout_r, rings=6, segments=12)
    m.joints["Head"] = (0, 1.3, -0.22)
    face, _ = _face(m, hc, hr, eye_yaw=30, eye_pitch=18, eye_size=0.13, mouth=False)
    smile(face, snout_c, snout_r, pitch=-16, width=36, depth=7, thickness=0.028, steps=8)
    _nostrils(face, snout_c, snout_r, yaw=16, pitch=42, size=0.03)
    gold = m.piece("HeadStar", GOLD, material=MAT)
    top = hc[1] + hr[1]
    star(gold, (0, top + 0.12, hc[2] + 0.04), 0.2, 0.08, normal=(0, 0, -1))
    sail = m.piece("GlowSail", SAIL_PINK, material="Neon")
    # Sail in the YZ plane (normal +X): local x runs toward -Z, so x = z0 - z. Base follows the
    # back 0.12 under its surface (buried), the top is a row of rounded spines.
    z0 = 0.25
    base = [(z0 - z, _overside(bc, br_, 0, z) - 0.12) for z in (0.72, 0.5, 0.25, 0.0, -0.22)]
    spines = [(0.66, 0.42), (0.55, 0.66), (0.4, 0.86), (0.25, 0.96), (0.08, 0.92), (-0.08, 0.78), (-0.2, 0.54)]
    top_pts = []
    for i, (z, h) in enumerate(spines):
        y = _overside(bc, br_, 0, z) + h
        top_pts.append((z0 - z, y))
        if i < len(spines) - 1:  # scallop dip between spines
            zn, hn = spines[i + 1]
            top_pts.append((z0 - (z + zn) / 2, _overside(bc, br_, 0, (z + zn) / 2) + min(h, hn) * 0.82))
    outline = [(x, y - 1.0) for x, y in base[::-1]] + [(x, y - 1.0) for x, y in top_pts]
    plate(sail, outline, (0, 1.0, z0), (1, 0, 0), (0, 1, 0), 0.07)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    for yaw, pitch, s in ((70, 20, 0.11), (-70, 20, 0.11), (110, 4, 0.09), (-110, 4, 0.09), (140, 30, 0.08), (-140, 30, 0.08)):
        p, n = surface(bc, br_, yaw, pitch)
        plate(glow, star_outline(s, s * 0.42, points=4, rotate=90), tup(p + n * 0.02), tup(n), (0, 1, 0), 0.04)
    tail = m.piece("Tail", SPINO_VIOLET, material=MAT)
    pts = _tail(tail, [(0, 0.86, 0.55), (0, 0.76, 0.95), (0, 0.78, 1.32), (0, 0.9, 1.6)], 0.27, 0.07, tip=False)
    end = v3(pts[-1])
    plate(tail, [(-0.02, -0.16), (0.2, 0.0), (-0.02, 0.18), (-0.08, 0.0)], tup(end + Vector((0, 0, 0.04))), (1, 0, 0), (0, 1, 0), 0.06)
    m.joints["Tail"] = (0, 0.86, 0.58)
    _orbit(m, (0, 1.15, 0.15), 1.16, color=SKY_GLOW, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


# ------------------------------------------------------------------------------------------------
# EXCLUSIVE (Time Traveler Pack — fixed grant, not random)
# ------------------------------------------------------------------------------------------------


def build_time_ptero():
    """Time Ptero: teal ptero in brass goggles with a glowing clock-face belly (Time Traveler Pack)."""
    m = _pet("TimePtero", "Epic", hover=1.0)
    body = m.piece("Body", TIME_TEAL, material=MAT)
    bc, br_ = (0, 0.72, 0.05), (0.44, 0.5, 0.48)
    _blob(body, bc, br_)
    for sx in (-1, 1):  # stubby round feet + a little tail point
        tube(body, [(sx * 0.18, 0.32, 0.1), (sx * 0.2, 0.08, 0.0)], 0.06, sides=6)
        ellipsoid(body, (sx * 0.2, 0.05, -0.06), (0.09, 0.05, 0.13), rings=4, segments=8)
    tube(body, [(0, 0.55, 0.45), (0, 0.42, 0.78)], 0.09, sides=6, radii=[0.1, 0.03])
    # Clock face: a cream disc on the belly; Neon ticks + hands follow the disc's dome.
    belly = m.piece("Belly", CREAM, material=MAT)
    p, n = surface(bc, br_, 0, -4)
    face_r, face_t = 0.3, 0.1
    centre = p - n * 0.06
    oriented_ellipsoid(belly, tup(centre), (face_r, face_r, face_t), normal=tup(n), rings=6, segments=14)
    glow = m.piece("Glow", SKY_GLOW, material="Neon")
    s_, u_, n_ = frame(n)

    def on_dial(x, y, lift=0.012):
        """Point on the clock dial's dome at local (x, y), just proud of the surface."""
        r = min(math.hypot(x, y) / face_r, 0.999)
        return tup(centre + s_ * x + u_ * y + n_ * (face_t * math.sqrt(1 - r * r) + lift))

    for k in range(12):
        a = 2 * math.pi * k / 12
        size = 0.032 if k % 3 == 0 else 0.022
        ellipsoid(glow, on_dial(0.23 * math.sin(a), 0.23 * math.cos(a)), (size, size, size), rings=3, segments=6)
    tube(glow, [on_dial(0, 0), on_dial(0, 0.09), on_dial(0, 0.17)], 0.024, sides=4)  # minute hand (12)
    tube(glow, [on_dial(0, 0), on_dial(-0.06, 0.035), on_dial(-0.11, 0.065)], 0.026, sides=4)  # hour hand (10)
    ellipsoid(glow, on_dial(0, 0, 0.02), (0.036, 0.036, 0.036), rings=3, segments=6)
    head = m.piece("Head", TIME_TEAL, material=MAT)
    hc, hr = (0, 1.36, -0.2), (0.42, 0.4, 0.42)
    _blob(head, hc, hr, rings=10, segments=16)
    _ptero_head_crest(head, hc, hr, length=0.5)
    m.joints["Head"] = (0, 1.02, -0.1)
    _, shine = _face(m, hc, hr, eye_yaw=32, eye_pitch=8, eye_size=0.13, mouth=False)
    beak = m.piece("HeadBeak", BEAK_GOLD, material=MAT)
    p, n = surface(hc, hr, 0, -16)
    _round_spike(beak, tup(p - n * 0.12), tup(p + n * 0.34 + Vector((0, -0.05, 0))), 0.13, ball=0.06)
    goggles = m.piece("HeadGoggles", BRASS, material=MAT)
    strap = []
    for k in range(18):  # strap round the head above the eyes
        q, nq = surface(hc, hr, 360.0 * k / 18, 36)
        strap.append(tup(q + nq * 0.015))
    tube(goggles, strap, 0.04, sides=5, closed=True)
    for side in (-1, 1):  # two round lenses pushed up on the forehead (lens glass = the white shine)
        q, nq = surface(hc, hr, side * 24, 40)
        c = q + nq * 0.05
        tube(goggles, circle_points(tup(c), 0.12, normal=tup(nq), segments=12, up=(0, 1, 0)), 0.035, sides=5, closed=True)
        oriented_ellipsoid(shine, tup(c - nq * 0.01), (0.105, 0.105, 0.03), normal=tup(nq), rings=3, segments=12)
    _ptero_wings(m, TIME_WING, (0.36, 0.95, 0.0))
    return _done(m)


BUILDERS = {
    "AtomRaptor": build_atom_raptor,
    "GlowStego": build_glow_stego,
    "FissionTrike": build_fission_trike,
    "PocketBronto": build_pocket_bronto,
    "EmberAnkylo": build_ember_ankylo,
    "MagmaPtero": build_magma_ptero,
    "LavaPara": build_lava_para,
    "SupernovaSpino": build_supernova_spino,
    "TimePtero": build_time_ptero,
}
