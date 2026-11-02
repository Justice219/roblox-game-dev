"""
pets_moon.py — the World 3 "Moon Base" pet roster: round, big-eyed, candy-bright space critters
(spec docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §2.5, owner R70). Same art
contract as pets.py / pets_dino.py (B8f / W11):

    * ONE Blender model per pet, <= 10 single-colour pieces (<= 10 draw calls), <= 2,800 triangles.
    * Bodies `StudsSmall`, faces / eyes `Smooth`, glowing bits `Neon` (small accents only: R19),
      helmet / saucer domes `Glass`.
    * ORIGIN = ground-contact centre (y = 0 under the pet's middle); the pet FACES -Z; +X is its
      right-hand side; 1.8-2.6 studs tall. Flyers / floaters get `hover`.
    * Piece-name prefix = PetAnim animation group (docs/pets-art.md §1, Client/Pets/PetAnim):
        Head*            head / ears / face / crest / horn / cap / mane       -> joint "Head"
        Tail*            tail + tuft / star / tentacle skirt                  -> joint "Tail"
        WingL* / WingR*  wings and flippers                                   -> joints "WingL" / "WingR"
        Orbit*           Neon rings (Rare+)                                  -> joint "Orbit" (spins)
        anything else    the rigid Body (Body / Belly / Collar squash; Glow* pulses, R19-safe)
      Joints ship in the pivot string (`joints Head@(x,y,z) ...`, pets._done) and every animated
      group is buried in its host at the joint, so a nod / wag / flap never opens a gap.
    * Styles: PetAnim derives Walk / Fly (hover + wings) / Float (hover, no wings); PetAnimConfig
      overrides Moon Bunny -> Hop, Galaxy Whale -> Swim (fluke thumps, Pitch), Saucer Octo's
      tentacle skirt -> Sway.

Kid-friendly + candy-vivid (owner R47 / R70; judged with tools/blender/viewport_look.py): nothing
sharp — horns, antennae and rocket noses end in balls; aliens / pets smile; no real flags.

Roster (key — display name — rarity — egg — hover — look):
    AstroPup          Astro Pup          Uncommon   Moon Egg     0    snow-white pup in a sky-blue space
                                                                      suit, coral jetpack with Neon jets,
                                                                      lavender floppy ears, antenna band
    MoonBunny         Moon Bunny         Rare       Moon Egg     0    lilac bunny, long ears, Neon crescent
                                                                      moon on the forehead, one ring
    OrbitOwl          Orbit Owl          Epic       Moon Egg     0.8  sunshine-yellow owl with its own
                                                                      banded Saturn ring + a tiny moon
    CosmoCat          Cosmo Cat          Legendary  Moon Egg     0    electric-blue cat, Neon star spots,
                                                                      gold star collar + tail star, 2 rings
    CometFox          Comet Fox          Rare       Comet Egg    0    icy-cyan fox, white mask, a bushy
                                                                      tail streaming a Neon comet trail
    SaucerOcto        Saucer Octo        Epic       Comet Egg    0.6  coral octopus in a glass-domed
                                                                      flying saucer with Neon rim lights
    GalaxyWhale       Galaxy Whale       Legendary  Comet Egg    1.0  violet sky-whale, star freckles, a
                                                                      Neon star spout, gold crown, 2 rings
    StarlightUnicorn  Starlight Unicorn  Mythic     Comet Egg    0.6  mint pony, hot-pink mane, gold
                                                                      spiral horn, Neon star wings, a ring
    RocketCorgi       Rocket Corgi       Epic       Astronaut    0.5  orange corgi in a red aviator cap
                                         (pack, fixed)                astride a white toy rocket (Neon flame)

Build / preview / ship (docs/pets-art.md §11):
    KEYS=AstroPup,MoonBunny,OrbitOwl,CosmoCat,CometFox,SaucerOcto,GalaxyWhale,StarlightUnicorn,RocketCorgi
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only $KEYS
    /opt/homebrew/bin/blender -b --python tools/blender/viewport_look.py -- OUT $KEYS tools/blender/models/pets_moon.py
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.shapes import cylinder, ellipsoid

from models._critter_kit import (
    GOLD,
    SNOW,
    SOFT_BLACK,
    SUN_GLOW,
    circle_points,
    crown,
    frame,
    orbit_ring,
    oriented_ellipsoid,
    plate,
    star,
    star_outline,
    surface,
    tube,
    tup,
    v3,
)
from models.pets import (
    MAT,
    _blob,
    _done,
    _ear_floppy,
    _ear_long,
    _ear_tri,
    _face,
    _horn,
    _legs,
    _muzzle,
    _nose,
    _orbit,
    _pet,
    _spots,
    _tail,
    _wing_plate,
)
from models.pets_dino import _belly_patch, _round_spike

# Moon Base palette (spec §2.2 "chrome-white + candy accents": mint, coral, sunshine, violet) —
# every species reads at a glance at pet size.
PUP_WHITE = (246, 246, 255)
SUIT_BLUE = (84, 176, 255)
CORAL = (255, 104, 88)
EAR_LAVENDER = (186, 140, 255)
BUNNY_LILAC = (190, 150, 255)
EAR_PINK = (255, 156, 206)
MOON_YELLOW = (255, 226, 70)
OWL_SUN = (255, 206, 40)
OWL_ORANGE = (255, 138, 34)
OWL_CREAM = (255, 246, 214)
RING_MINT = (110, 246, 204)
CAT_BLUE = (74, 118, 255)
RING_PINK = (255, 92, 190)
FOX_CYAN = (96, 214, 255)
COMET_GLOW = (255, 248, 190)
OCTO_CORAL = (255, 108, 138)
OCTO_SPOT = (255, 186, 206)
SAUCER_SILVER = (214, 218, 248)
SAUCER_BELLY = (150, 140, 236)
DOME_GLASS = (196, 236, 255)
WHALE_VIOLET = (108, 82, 248)
WHALE_BELLY = (232, 196, 255)
UNI_MINT = (110, 236, 200)
MANE_PINK = (255, 96, 186)
WING_GLOW = (255, 236, 150)
HALO_PINK = (255, 150, 222)
CORGI_ORANGE = (255, 158, 58)
CAP_RED = (236, 58, 66)
ROCKET_FLAME = (255, 176, 50)


# ------------------------------------------------------------------------------------------------
# Shared space-critter parts
# ------------------------------------------------------------------------------------------------


def _crescent(radius, steps=7):
    """2-D crescent-moon outline (opening to +x): an outer arc minus an offset inner arc."""
    outer = [(radius * math.cos(math.radians(a)), radius * math.sin(math.radians(a)))
             for a in [60 + (300 - 60) * i / steps for i in range(steps + 1)]]
    inner_r, shift = radius * 0.78, radius * 0.42
    inner = [(shift + inner_r * math.cos(math.radians(a)), inner_r * math.sin(math.radians(a)))
             for a in [255 - (255 - 105) * i / steps for i in range(steps + 1)]]
    return outer + inner


def _star_plate(piece, center, radii, yaw, pitch, size, points=4, lift=0.02, thick=0.04):
    """A small star plate stuck on an ellipsoid surface at (yaw, pitch)."""
    p, n = surface(center, radii, yaw, pitch)
    plate(piece, star_outline(size, size * 0.42, points=points), tup(p + n * lift), tup(n), (0, 1, 0), thick)


# ------------------------------------------------------------------------------------------------
# MOON EGG (Moon area 2): Uncommon / Rare / Epic / Legendary
# ------------------------------------------------------------------------------------------------


def build_astro_pup():
    """Astro Pup: snow-white pup in a sky-blue space suit with a coral jetpack and an antenna band."""
    m = _pet("AstroPup", "Uncommon")
    body = m.piece("Body", PUP_WHITE, material=MAT)
    bc, br_ = (0, 0.7, 0.18), (0.55, 0.5, 0.66)
    _blob(body, bc, br_)
    _legs(body, bc, br_, leg_r=0.19)
    head = m.piece("Head", PUP_WHITE, material=MAT)
    hc, hr = (0, 1.42, -0.28), (0.66, 0.56, 0.56)
    _blob(head, hc, hr, rings=10, segments=16)
    mc, mr = _muzzle(head, hc, hr, size=(0.28, 0.2, 0.2), pitch=-16)
    m.joints["Head"] = (0, 1.07, -0.1)
    suit = m.piece("Belly", SUIT_BLUE, material=MAT)  # suit chest + neck ring (squashes with the body)
    _belly_patch(suit, bc, br_, -6, (0.44, 0.42, 0.16))
    ring = circle_points((0, 1.04, -0.08), 0.37, normal=(0, 1, -0.35), segments=14)
    tube(suit, ring, 0.075, sides=5, closed=True)
    pack = m.piece("Pack", CORAL, material=MAT)  # jetpack: two tanks + a strap plate on the back
    for sx in (-1, 1):
        cylinder(pack, (sx * 0.17, 0.62, 0.8), (sx * 0.17, 1.06, 0.8), 0.13, segments=10)
        ellipsoid(pack, (sx * 0.17, 1.06, 0.8), (0.13, 0.07, 0.13), rings=4, segments=10)
    plate(pack, [(-0.28, -0.14), (0.28, -0.14), (0.28, 0.14), (-0.28, 0.14)], (0, 0.86, 0.74), (0, 0, 1), (0, 1, 0), 0.08)
    glow = m.piece("Glow", ROCKET_FLAME, material="Neon")  # jet flames + a chest star badge
    for sx in (-1, 1):
        cylinder(glow, (sx * 0.17, 0.62, 0.8), (sx * 0.17, 0.34, 0.86), 0.1, segments=8, radius_b=0.02)
    p, n = surface(bc, br_, 0, 4)
    star(glow, tup(p + n * 0.05), 0.11, 0.04, normal=tup(n))
    ears = m.piece("HeadEars", EAR_LAVENDER, material=MAT)
    for side in (-1, 1):
        _ear_floppy(ears, hc, hr, side, yaw=74, pitch=30, length=0.44, width=0.21)
    face, _ = _face(m, hc, hr, eye_yaw=27, eye_pitch=8, eye_size=0.15, mouth=False)
    _nose(face, mc, mr, pitch=30, size=(0.1, 0.07, 0.07))
    antenna = m.piece("HeadAntenna", CORAL, material=MAT)  # headband over the crown + a ball-tip antenna
    band = []
    for k in range(9):
        q, nq = surface(hc, hr, -70 + 140 * k / 8, 64)
        band.append(tup(q + nq * 0.02))
    tube(antenna, band, 0.045, sides=5)
    top, nt = surface(hc, hr, 30, 72)
    tube(antenna, [tup(top), tup(top + Vector((0.06, 0.34, 0.04)))], 0.03, sides=5)
    ellipsoid(antenna, tup(top + Vector((0.06, 0.4, 0.04))), (0.08, 0.08, 0.08), rings=4, segments=8)
    tail = m.piece("Tail", PUP_WHITE, material=MAT)
    _tail(tail, [(0, 0.82, 0.72), (0, 1.05, 0.92), (0, 1.2, 0.98)], 0.11, 0.07)
    m.joints["Tail"] = (0, 0.82, 0.74)
    return _done(m)


def build_moon_bunny():
    """Moon Bunny: lilac bunny, tall ears with pink insides, a Neon crescent moon mark, one ring."""
    m = _pet("MoonBunny", "Rare")
    body = m.piece("Body", BUNNY_LILAC, material=MAT)
    bc, br_ = (0, 0.62, 0.12), (0.55, 0.55, 0.6)
    _blob(body, bc, br_)
    for sx in (-1, 1):  # big back feet + little front paws
        ellipsoid(body, (sx * 0.3, 0.1, 0.12), (0.2, 0.11, 0.32), rings=5, segments=10)
        ellipsoid(body, (sx * 0.22, 0.12, -0.36), (0.12, 0.1, 0.14), rings=4, segments=8)
    belly = m.piece("Belly", SNOW, material=MAT)
    _belly_patch(belly, bc, br_, -10, (0.36, 0.42, 0.14))
    head = m.piece("Head", BUNNY_LILAC, material=MAT)
    hc, hr = (0, 1.28, -0.22), (0.6, 0.52, 0.52)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 0.98, -0.1)
    inner = m.piece("HeadEarsInner", EAR_PINK, material="Smooth")
    for side in (-1, 1):
        _ear_long(head, inner, hc, hr, side, yaw=22, pitch=62, length=0.46, width=0.17)
    p, n = surface(hc, hr, 0, -4)  # little pink nose
    oriented_ellipsoid(inner, tup(p + n * 0.01), (0.07, 0.05, 0.04), normal=tup(n), rings=4, segments=8)
    face, _ = _face(m, hc, hr, eye_yaw=28, eye_pitch=8, eye_size=0.15, mouth_pitch=-16, mouth_w=12)
    glow = m.piece("HeadGlow", MOON_YELLOW, material="Neon")  # crescent moon mark (pulses with the head)
    p, n = surface(hc, hr, 0, 36)
    plate(glow, _crescent(0.15), tup(p + n * 0.02), tup(n), (0, 1, 0), 0.04)
    tail = m.piece("Tail", SNOW, material=MAT)  # cotton puff
    ellipsoid(tail, (0, 0.62, 0.72), (0.2, 0.2, 0.18), rings=6, segments=10)
    m.joints["Tail"] = (0, 0.62, 0.62)
    _orbit(m, (0, 1.0, 0.1), 1.04, color=MOON_YELLOW, rings=((-22.0, -18.0),))
    return _done(m)


def build_orbit_owl():
    """Orbit Owl: round sunshine-yellow owl wearing its own banded Saturn ring with a tiny moon."""
    m = _pet("OrbitOwl", "Epic", hover=0.8)
    body = m.piece("Body", OWL_SUN, material=MAT)
    bc, br_ = (0, 0.82, 0.02), (0.68, 0.76, 0.64)
    _blob(body, bc, br_, rings=10, segments=16)
    for sx in (-1, 1):  # little toes (body colour)
        for k in (-1, 0, 1):
            ellipsoid(body, (sx * 0.24 + k * 0.08, 0.05, -0.38), (0.05, 0.05, 0.1), rings=4, segments=6)
    belly = m.piece("Belly", OWL_CREAM, material=MAT)
    _belly_patch(belly, bc, br_, -12, (0.44, 0.5, 0.14))
    head = m.piece("Head", OWL_SUN, material=MAT)
    hc, hr = (0, 1.66, -0.06), (0.6, 0.48, 0.54)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 1.34, -0.02)
    shine = m.piece("HeadShine", SNOW, material="Smooth")  # big white eye discs + highlights
    face = m.piece("HeadFace", SOFT_BLACK, material="Smooth")
    for side in (-1, 1):
        p, n = surface(hc, hr, side * 26, 6)
        oriented_ellipsoid(shine, tup(p - n * 0.02), (0.23, 0.23, 0.07), normal=tup(n), rings=5, segments=14)
        pc = p + n * 0.04
        oriented_ellipsoid(face, tup(pc), (0.12, 0.14, 0.05), normal=tup(n), rings=5, segments=10)
        s_, u_, n_ = frame(n)
        oriented_ellipsoid(shine, tup(pc + n_ * 0.05 + u_ * 0.06 - s_ * side * 0.04), (0.05, 0.05, 0.03), normal=tup(n), rings=4, segments=8)
    beak = m.piece("HeadBeak", OWL_ORANGE, material=MAT)
    p, n = surface(hc, hr, 0, -8)
    plate(beak, [(-0.09, 0.05), (0.09, 0.05), (0.0, -0.15)], tup(p + n * 0.04), tup(n), (0, 1, 0), 0.11)
    for side in (-1, 1):  # orange ear tufts (Head group)
        q, _ = surface(hc, hr, side * 40, 52)
        plate(beak, [(-0.12, 0), (0.12, 0), (0.05, 0.3), (-0.02, 0.34)], tup(q - Vector((0, 0.06, 0))), (0, 0, -1), (side * 0.5, 1, 0), 0.1)
    for side, name in ((-1, "WingL"), (1, "WingR")):
        wing = m.piece(name, OWL_ORANGE, material=MAT)
        oriented_ellipsoid(wing, (side * 0.7, 0.86, 0.1), (0.46, 0.3, 0.1), normal=(side, 0, -0.15), up=(0, 0.4, 0.9), rings=6, segments=10)
        m.joints[name] = (side * 0.58, 1.12, 0.04)
    ring = m.piece("Orbit", RING_MINT, material="Neon")  # Saturn ring: two bands + a tiny moon
    centre = (0, 0.86, 0.02)
    orbit_ring(ring, centre, 0.98, 0.04, tilt_x=12, tilt_z=-10, segments=30, sides=5, electrons=1, electron_r=0.1)
    orbit_ring(ring, centre, 1.12, 0.035, tilt_x=12, tilt_z=-10, segments=30, sides=5)
    m.joints["Orbit"] = centre
    return _done(m)


def build_cosmo_cat():
    """Cosmo Cat: electric-blue cat, Neon star spots, gold star collar + tail star, two pink rings."""
    m = _pet("CosmoCat", "Legendary")
    body = m.piece("Body", CAT_BLUE, material=MAT)
    bc, br_ = (0, 0.66, 0.16), (0.5, 0.48, 0.62)
    _blob(body, bc, br_)
    _legs(body, bc, br_, leg_r=0.17)
    head = m.piece("Head", CAT_BLUE, material=MAT)
    hc, hr = (0, 1.36, -0.26), (0.62, 0.52, 0.54)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 1.02, -0.08)
    inner = m.piece("HeadEarsInner", EAR_PINK, material="Smooth")
    for side in (-1, 1):
        _ear_tri(head, inner, hc, hr, side, yaw=36, pitch=48, w=0.22, h=0.46)
    p, n = surface(hc, hr, 0, -8)  # pink nose
    oriented_ellipsoid(inner, tup(p + n * 0.01), (0.07, 0.05, 0.04), normal=tup(n), rings=4, segments=8)
    _face(m, hc, hr, eye_yaw=28, eye_pitch=6, eye_size=0.16, mouth_pitch=-18, mouth_w=12)
    collar = m.piece("Collar", GOLD, material=MAT)  # gold collar + a star tag
    tube(collar, circle_points((0, 1.0, -0.14), 0.36, normal=(0, 1, -0.3), segments=14), 0.06, sides=5, closed=True)
    star(collar, (0, 0.86, -0.5), 0.14, 0.06, normal=(0, -0.2, -1))
    glow = m.piece("Glow", SUN_GLOW, material="Neon")  # four-point star spots
    for yaw, pitch, s in ((70, 28, 0.1), (-70, 28, 0.1), (130, 40, 0.09), (-130, 40, 0.09), (180, 58, 0.08)):
        _star_plate(glow, bc, br_, yaw, pitch, s)
    tail = m.piece("Tail", CAT_BLUE, material=MAT)
    pts = _tail(tail, [(0, 0.66, 0.72), (0.1, 0.95, 1.0), (0.05, 1.35, 1.08), (-0.08, 1.55, 0.95)], 0.1, 0.08, tip=False)
    m.joints["Tail"] = (0, 0.66, 0.74)
    tstar = m.piece("TailStar", GOLD, material=MAT)
    star(tstar, tup(v3(pts[-1]) + Vector((0, 0.08, 0))), 0.17, 0.08, normal=(0, 0, -1))
    _orbit(m, (0, 1.0, 0.12), 1.08, color=RING_PINK, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


# ------------------------------------------------------------------------------------------------
# COMET EGG (Moon area 5): Rare / Epic / Legendary / Mythic
# ------------------------------------------------------------------------------------------------


def build_comet_fox():
    """Comet Fox: icy-cyan fox with a white mask and a bushy tail streaming a Neon comet trail."""
    m = _pet("CometFox", "Rare")
    body = m.piece("Body", FOX_CYAN, material=MAT)
    bc, br_ = (0, 0.66, 0.16), (0.5, 0.46, 0.64)
    _blob(body, bc, br_)
    _legs(body, bc, br_, leg_r=0.16)
    belly = m.piece("Belly", SNOW, material=MAT)
    _belly_patch(belly, bc, br_, -12, (0.32, 0.36, 0.14))
    head = m.piece("Head", FOX_CYAN, material=MAT)
    hc, hr = (0, 1.34, -0.28), (0.6, 0.5, 0.52)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 1.0, -0.1)
    mask = m.piece("HeadAccent", SNOW, material=MAT)  # white cheeks / muzzle + inner ears
    mc, mr = _muzzle(mask, hc, hr, size=(0.3, 0.2, 0.24), pitch=-16)
    for side in (-1, 1):
        _ear_tri(head, mask, hc, hr, side, yaw=34, pitch=48, w=0.22, h=0.5)
        q, nq = surface(hc, hr, side * 40, -16)
        oriented_ellipsoid(mask, tup(q - nq * 0.04), (0.2, 0.15, 0.12), normal=tup(nq), rings=4, segments=10)
    face, _ = _face(m, hc, hr, eye_yaw=26, eye_pitch=10, eye_size=0.15, mouth=False)
    _nose(face, mc, mr, pitch=30, size=(0.09, 0.07, 0.07))
    tail = m.piece("Tail", FOX_CYAN, material=MAT)  # bushy tail that thickens toward the tip
    pts = _tail(tail, [(0, 0.72, 0.68), (0, 0.98, 1.02), (0, 1.32, 1.2), (0, 1.58, 1.18)], 0.15, 0.27)
    m.joints["Tail"] = (0, 0.72, 0.7)
    trail = m.piece("TailGlow", COMET_GLOW, material="Neon")  # comet trail streaming off the tip
    tip = v3(pts[-1])
    star(trail, tup(tip + Vector((0, 0.3, -0.02))), 0.16, 0.06, normal=(0, 0, -1))
    for dx, dz in ((-0.12, 0.0), (0.0, 0.06), (0.12, 0.0)):
        tube(trail, [tup(tip + Vector((dx * 0.5, 0.16, dz))), tup(tip + Vector((dx, -0.05, 0.42 + dz))), tup(tip + Vector((dx * 1.4, -0.3, 0.7 + dz)))],
             0.04, sides=4, radii=[0.05, 0.035, 0.015])
    _orbit(m, (0, 0.98, 0.12), 1.06, color=COMET_GLOW, rings=((-22.0, -18.0),))
    return _done(m)


def build_saucer_octo():
    """Saucer Octo: a coral octopus riding a glass-domed flying saucer with Neon rim lights."""
    m = _pet("SaucerOcto", "Epic", hover=0.6)
    saucer = m.piece("Body", SAUCER_SILVER, material=MAT)
    ellipsoid(saucer, (0, 0.55, 0), (0.95, 0.2, 0.95), rings=6, segments=20)
    ellipsoid(saucer, (0, 0.66, 0), (0.66, 0.14, 0.66), rings=5, segments=18)  # upper deck under the dome
    belly = m.piece("Belly", SAUCER_BELLY, material=MAT)  # violet underside dome
    ellipsoid(belly, (0, 0.44, 0), (0.56, 0.16, 0.56), rings=5, segments=16)
    lights = m.piece("Glow", SUN_GLOW, material="Neon")  # rim bulbs
    for k in range(10):
        a = 2 * math.pi * k / 10
        ellipsoid(lights, (0.93 * math.sin(a), 0.55, -0.93 * math.cos(a)), (0.07, 0.07, 0.07), rings=3, segments=6)
    dome = m.piece("Dome", DOME_GLASS, material="Glass", transparency=0.55)
    ellipsoid(dome, (0, 0.98, 0), (0.6, 0.6, 0.6), rings=8, segments=16)
    head = m.piece("Head", OCTO_CORAL, material=MAT)  # the octopus inside the dome
    hc, hr = (0, 0.98, -0.02), (0.42, 0.42, 0.4)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 0.74, 0)
    spots = m.piece("HeadSpots", OCTO_SPOT, material="Smooth")
    _spots(spots, hc, hr, [(60, 40), (-60, 40), (150, 30), (-150, 30), (180, 60, 0.8)], size=0.08)
    _face(m, hc, hr, eye_yaw=26, eye_pitch=4, eye_size=0.12, mouth_pitch=-22, mouth_w=14)
    tail = m.piece("Tail", OCTO_CORAL, material=MAT)  # six curly tentacles hanging below the saucer
    for k in range(6):
        a = 2 * math.pi * (k + 0.5) / 6
        ox, oz = math.sin(a), -math.cos(a)
        ctrl = [(ox * 0.3, 0.42, oz * 0.3), (ox * 0.5, 0.22, oz * 0.5), (ox * 0.62, 0.06, oz * 0.62), (ox * 0.55, -0.06, oz * 0.48)]
        _tail(tail, ctrl, 0.09, 0.04, sides=5, per=2, tip=False)
    m.joints["Tail"] = (0, 0.42, 0)
    return _done(m)


def build_galaxy_whale():
    """Galaxy Whale: violet sky-whale with star freckles, a Neon star spout, gold crown, two rings."""
    m = _pet("GalaxyWhale", "Legendary", hover=1.0)
    body = m.piece("Body", WHALE_VIOLET, material=MAT)
    bc, br_ = (0, 0.68, 0.1), (0.76, 0.66, 0.98)

    def taper(x, y, z):
        # Narrow the back half toward the tail stock (the whale reads front-heavy and friendly).
        f = 1.0 - 0.45 * max(0.0, z / 0.98) ** 1.5
        return (x * f, y * f + 0.08 * max(0.0, z), z)

    _blob(body, bc, br_, rings=10, segments=16, deform=taper)
    belly = m.piece("Belly", WHALE_BELLY, material=MAT)  # pale belly with groove stripes
    oriented_ellipsoid(belly, (0, 0.28, -0.08), (0.52, 0.14, 0.72), normal=(0, -1, -0.2), up=(0, 0, 1), rings=6, segments=12)
    for k in range(3):
        x = (k - 1) * 0.16
        tube(belly, [(x, 0.18, -0.6), (x, 0.12, -0.2), (x, 0.14, 0.2)], 0.035, sides=4)
    hc, hr = (0, 0.7, 0.0), (0.74, 0.66, 0.94)
    _face(m, hc, hr, prefix="", eye_yaw=30, eye_pitch=8, eye_size=0.16, mouth_pitch=-14, mouth_w=16)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")  # star freckles + the star-fountain spout
    for yaw, pitch, s in ((140, 40, 0.09), (-140, 40, 0.09), (160, 18, 0.08), (-160, 18, 0.08), (110, 25, 0.07), (-110, 25, 0.07)):
        _star_plate(glow, bc, br_, yaw, pitch, s)
    tube(glow, [(0, 1.26, -0.2), (0, 1.5, -0.24), (0, 1.62, -0.24)], 0.04, sides=5)
    for k, (dx, dy) in enumerate(((-0.16, 1.68), (0.0, 1.76), (0.16, 1.68))):
        star(glow, (dx, dy, -0.24), 0.09 - 0.01 * (k % 2), 0.04, normal=(0, 0, -1))
    band = m.piece("Crown", GOLD, material=MAT)
    crown(band, band, (0, 1.22, -0.48), 0.18, 0.22, points=4, segments=12)
    tail = m.piece("Tail", WHALE_VIOLET, material=MAT)
    fluke = [(0, -0.05), (0.42, 0.25), (0.56, 0.44), (0.3, 0.33), (0.0, 0.18), (-0.3, 0.33), (-0.56, 0.44), (-0.42, 0.25)]
    plate(tail, fluke, (0, 0.95, 1.06), (0, 1, 0), (0, 0, 1), 0.1)
    tube(tail, [(0, 0.82, 0.86), (0, 0.95, 1.12)], 0.13, sides=6)
    m.joints["Tail"] = (0, 0.85, 0.86)
    for side, name in ((-1, "WingL"), (1, "WingR")):
        fin = m.piece(name, WHALE_VIOLET, material=MAT)
        oriented_ellipsoid(fin, (side * 0.76, 0.36, -0.12), (0.34, 0.08, 0.18), normal=(0, 1, 0), up=(side, 0, 0.5), rings=5, segments=10)
        m.joints[name] = (side * 0.6, 0.42, -0.12)
    _orbit(m, (0, 0.75, 0.05), 1.1, color=SUN_GLOW, rings=((-24.0, -20.0), (-10.0, 36.0)))
    return _done(m)


def build_starlight_unicorn():
    """Starlight Unicorn: mint pony, hot-pink mane, gold spiral horn, glowing star wings, a pink ring."""
    m = _pet("StarlightUnicorn", "Mythic", hover=0.6)
    body = m.piece("Body", UNI_MINT, material=MAT)
    bc, br_ = (0, 0.78, 0.16), (0.5, 0.48, 0.66)
    _blob(body, bc, br_)
    _legs(body, bc, br_, leg_r=0.14)
    head = m.piece("Head", UNI_MINT, material=MAT)
    hc, hr = (0, 1.46, -0.36), (0.48, 0.46, 0.48)
    _blob(head, hc, hr, rings=10, segments=16)
    _muzzle(head, hc, hr, size=(0.26, 0.22, 0.22), pitch=-20)
    m.joints["Head"] = (0, 1.1, -0.18)
    for side in (-1, 1):
        _ear_tri(head, None, hc, hr, side, yaw=44, pitch=46, w=0.13, h=0.28, lean=18, thick=0.1)
    mane = m.piece("HeadMane", MANE_PINK, material=MAT)
    for yaw, pitch in ((0, 58), (180, 80), (180, 48), (180, 18)):
        q, nq = surface(hc, hr, yaw, pitch)
        ellipsoid(mane, tup(q - nq * 0.04), (0.14, 0.16, 0.15), rings=3, segments=7)
    for k in range(3):  # mane down the neck
        ellipsoid(mane, (0.02 * (k % 2), 1.18 - 0.12 * k, 0.04 + 0.12 * k), (0.13, 0.15, 0.14), rings=3, segments=7)
    horn = m.piece("HeadHorn", GOLD, material=MAT)
    base, n = surface(hc, hr, 0, 50)
    _horn(horn, tup(base - n * 0.05), tup(base + Vector((0, 0.5, -0.2))), 0.1, turns=3, sides=6)
    ellipsoid(horn, tup(base + Vector((0, 0.5, -0.2))), (0.045, 0.045, 0.045), rings=4, segments=6)
    _face(m, hc, hr, eye_yaw=30, eye_pitch=8, eye_size=0.14, mouth_pitch=-26, mouth_w=12)
    # Glowing star-feather wings (Mythic: glowing wings), each WingL / WingR piece.
    outline = [(-0.05, 0.0), (0.25, 0.3), (0.5, 0.62), (0.62, 0.86), (0.66, 0.6), (0.82, 0.62), (0.78, 0.38),
               (0.94, 0.3), (0.76, 0.12), (0.58, 0.04), (0.3, -0.08)]
    for side, name in ((-1, "WingL"), (1, "WingR")):
        wing = m.piece(name, WING_GLOW, material="Neon")
        shoulder = (side * 0.3, 1.1, 0.18)
        _wing_plate(wing, outline, shoulder, side, back=0.6, lift=0.3, thick=0.07)
        m.joints[name] = shoulder
    tail = m.piece("Tail", MANE_PINK, material=MAT)
    _tail(tail, [(0, 0.98, 0.78), (0.1, 0.9, 1.06), (-0.05, 0.56, 1.2), (0.08, 0.3, 1.12)], 0.16, 0.11, sides=6)
    m.joints["Tail"] = (0, 0.98, 0.78)
    # Mythic flair = the glowing wings + gold horn; one pink ring with two star electrons.
    _orbit(m, (0, 1.0, 0.12), 1.08, color=HALO_PINK, rings=((-22.0, -18.0),), electrons=2)
    return _done(m)


# ------------------------------------------------------------------------------------------------
# EXCLUSIVE (Astronaut Pack — fixed grant, not random)
# ------------------------------------------------------------------------------------------------


def build_rocket_corgi():
    """Rocket Corgi: orange corgi in a red aviator cap riding a white toy rocket (Astronaut Pack)."""
    m = _pet("RocketCorgi", "Epic", hover=0.5)
    body = m.piece("Body", CORGI_ORANGE, material=MAT)
    bc, br_ = (0, 0.74, 0.2), (0.5, 0.4, 0.7)
    _blob(body, bc, br_)
    for sx in (-1, 1):  # four little paws gripping the rocket hull (it rides, it does not walk)
        for z in (-0.25, 0.55):
            ellipsoid(body, (sx * 0.29, 0.34, z), (0.12, 0.16, 0.14), rings=5, segments=8)
    ellipsoid(body, (0, 0.82, 0.88), (0.12, 0.1, 0.1), rings=4, segments=8)  # stubby tail
    belly = m.piece("Belly", SNOW, material=MAT)  # white chest + the toy rocket's white body
    _belly_patch(belly, bc, br_, -14, (0.34, 0.3, 0.14))
    # The rocket the corgi sits astride: horizontal under the belly, nose forward under the chin,
    # fins + flame behind. Its legs straddle the hull.
    rocket_a, rocket_b = Vector((0, 0.28, 0.98)), Vector((0, 0.28, -0.62))  # tail end, front end
    axis = (rocket_b - rocket_a).normalized()
    cylinder(belly, tup(rocket_a), tup(rocket_b), 0.26, segments=12)
    ellipsoid(belly, tup(rocket_a), (0.26, 0.26, 0.07), rings=4, segments=12)  # rounded tail cap
    fins = m.piece("RocketFins", CAP_RED, material=MAT)  # nose cone (ball tip) + three swept fins
    _round_spike(fins, tup(rocket_b), tup(rocket_b + axis * 0.36), 0.26, ball=0.08)
    for degrees in (90, 210, 330):
        a = math.radians(degrees)
        out = Vector((math.cos(a), math.sin(a), 0.0))
        # Fin plane = (rocket axis, radial `out`); outline x runs backward along the hull.
        plate(fins, [(0.0, 0.0), (0.3, 0.0), (0.42, 0.26), (0.12, 0.22)], tup(rocket_a - axis * 0.06 + out * 0.2),
              tup(out.cross(axis)), tup(out), 0.05)
    glow = m.piece("Glow", ROCKET_FLAME, material="Neon")  # rocket flame + two round portholes
    cylinder(glow, tup(rocket_a), tup(rocket_a - axis * 0.42), 0.19, segments=8, radius_b=0.03)
    for side in (-1, 1):
        oriented_ellipsoid(glow, (side * 0.26, 0.3, -0.36), (0.08, 0.08, 0.03), normal=(side, 0, 0), rings=4, segments=8)
    head = m.piece("Head", CORGI_ORANGE, material=MAT)
    hc, hr = (0, 1.36, -0.44), (0.56, 0.48, 0.5)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 1.06, -0.26)
    accent = m.piece("HeadAccent", SNOW, material=MAT)  # white muzzle + blaze + inner ears
    mc, mr = _muzzle(accent, hc, hr, size=(0.28, 0.2, 0.22), pitch=-16)
    for side in (-1, 1):
        _ear_tri(head, accent, hc, hr, side, yaw=40, pitch=40, w=0.24, h=0.52, lean=24)
    face, _ = _face(m, hc, hr, eye_yaw=28, eye_pitch=8, eye_size=0.15, mouth=False)
    _nose(face, mc, mr, pitch=30, size=(0.1, 0.07, 0.07))
    cap = m.piece("HeadCap", CAP_RED, material=MAT)  # aviator cap dome + ear flaps
    oriented_ellipsoid(cap, tup(Vector(hc) + Vector((0, 0.18, 0.08))), (0.5, 0.36, 0.46), normal=(0, 1, 0), up=(0, 0, -1), rings=6, segments=14)
    for side in (-1, 1):
        q, nq = surface(hc, hr, side * 72, 4)
        oriented_ellipsoid(cap, tup(q + nq * 0.02), (0.14, 0.2, 0.06), normal=tup(nq), rings=4, segments=8)
    return _done(m)


BUILDERS = {
    "AstroPup": build_astro_pup,
    "MoonBunny": build_moon_bunny,
    "OrbitOwl": build_orbit_owl,
    "CosmoCat": build_cosmo_cat,
    "CometFox": build_comet_fox,
    "SaucerOcto": build_saucer_octo,
    "GalaxyWhale": build_galaxy_whale,
    "StarlightUnicorn": build_starlight_unicorn,
    "RocketCorgi": build_rocket_corgi,
}
