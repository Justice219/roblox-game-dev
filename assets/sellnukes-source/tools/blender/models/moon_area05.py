"""
moon_area05.py — Moon Base area M5 "Star Lab" (R69-R71 spec §2.2, owner R70): a domed observatory
(producer), star jars, a giant telescope, a spinning planet mobile, a comet catcher, a friendly robot
arm, a moon garden, mission banners with bunting, and Dr. Nova (manager). Every pad purchase is its
own model set so each one builds in separately; placement lives in
src/shared/Config/Worlds/Moon/Layouts/Area05.luau (slot-local frame; docs/areas-art.md "Moon M5-M6").

This module also holds W8's Moon helpers used by moon_area06.py (importable, no side effects):
    moon_floor(...)   shared M5 / M6 ground (stripes, craters, tiles, rock wall, rocks, crystals)
    crystal(...), star_plate(...), round_tiles(...), ringed_planet(...)
Shared Moon helpers come from W6's models.moon_area01 (palette, crater, moon_rock, crystal_cluster,
moon_arch, toon_biped / toon_bones — every Moon manager uses that one body); generic ones from
models.dino_area05 (place_new, ribbon, text_both_at, clipboard).

Look (spec §2.2): pale lilac / moon-grey stud ground with craters, chrome-white + candy accents,
round friendly shapes; NOT Nuke Town's grey-metal hazard look. Kid rules: round, big-eyed, smiling.
Big glows are Smooth light colours, Neon only on small accents (owner R19).

Models (key: pivot / notes)                                              build key
    M5_Floor           SLOT ORIGIN pivot (layout cf = identity); top y = 0.5     base
    M5_EntryArch       ground centre between the posts (W6 moon_arch); "STAR LAB" base
    M5_LabDome         PRODUCER: ground centre (slot (0, 0.5, 50)); door -Z      M5_LabDome
                       Beacon on the antenna; Lamp = porch lamps (light)
    M5_StarJars        ground centre; shelf faces -Z                            M5_StarJars
    M5_BigTelescope    ground centre of the platform; tube points up toward -X  M5_BigTelescope
    M5_PlanetMobile    ground centre; Twirl* arms + planets spin about the pole  M5_PlanetMobile
    M5_CometCatcher    ground centre of the tripod; net faces -Z                M5_CometCatcher
    M5_RobotArm        ground centre of the turntable                           M5_RobotArm
    M5_MoonGarden      ground centre between the two planters                   M5_MoonGarden
    M5_DrNova          Manager (see build_dr_nova)                              M5_DrNova
    M5_MissionBanners  ground centre of the walkway; poles at x = +-9           M5_MissionBanners

Budgets (docs/world-art.md §4, spec §15): fully built area <= 28k triangles; models <= 6k / 24 pieces.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import Model
from snkit.kit import block, disc
from snkit.shapes import bar, cylinder, ellipsoid, prism, revolve, rot_x, rot_z

from models._critter_kit import circle_points, oriented_ellipsoid, smile, star, tube
from models.area01 import LOT_TOP, SLOT_PIVOT, lot_stripes
from models.area04 import Xf, _hash
from models.area09 import cable
from models.dino_area05 import clipboard as clipboard_helper
from models.dino_area05 import place_new, ribbon, text_both_at
from models.moon_area01 import (
    CHROME,
    CHROME_SHADE,
    CORAL_C,
    INK_M,
    MINT_C,
    MOON_DARK,
    MOON_GROUND,
    NAVY,
    ROCK_LILAC,
    STAR_GLOW,
    SUNNY,
    VIOLET,
    crater,
    crystal_cluster,
    moon_arch,
    moon_rock,
    toon_biped,
    toon_bones,
)

# ------------------------------------------------------------------------------------------------
# Palette: W6's shared Moon Base palette (models.moon_area01) under W8's names, plus W8 extras.
# ------------------------------------------------------------------------------------------------

MOON_LILAC = MOON_GROUND  # ground, stripe A
MOON_GREY = (190, 188, 210)  # ground, stripe B (a cooler second dust tone)
MOON_ROCK = ROCK_LILAC
MINT = MINT_C
CORAL = CORAL_C
NAVY_DARK = (32, 36, 88)
SUN_LIGHT = (255, 238, 150)  # big Smooth glows (R19)
LAVENDER = (196, 168, 255)
SKY = (124, 204, 255)
PINK = (255, 146, 204)
GLASS_TINT = (200, 232, 255)
EYE = INK_M
SHINE = (255, 255, 255)

SLOT_W = 104.0
SLOT_D = 70.0
T = LOT_TOP  # the floor plate top: every model in the layout stands at y = T


# ------------------------------------------------------------------------------------------------
# Moon helpers
# ------------------------------------------------------------------------------------------------


def crystal(piece, base, height, radius, tilt_x=0.0, tilt_z=0.0, segments=6):
    """Hexagonal space crystal: prism shaft + pointed tip, tilted (deg) about X then Z from `base`."""
    r = rot_z(tilt_z) @ rot_x(tilt_x)
    b = Vector(base)
    shoulder = b + r @ Vector((0, height * 0.72, 0))
    tip = b + r @ Vector((0, height, 0))
    cylinder(piece, tuple(b), tuple(shoulder), radius, segments=segments)
    cylinder(piece, tuple(shoulder), tuple(tip), radius, segments=segments, radius_b=0.04)


def star_plate(piece, center, outer, thickness=0.2, normal=(0, 0, -1), up=(0, 1, 0)):
    """Chunky five-point star plate (wrapper of _critter_kit.star with a friendlier fat inner ratio)."""
    star(piece, center, outer, thickness, normal=normal, up=up, inner_ratio=0.52)


def round_tiles(piece, z0, z1, top=T, step=2.7, seed=0):
    """Pairs of round chrome stepping tiles (discs, top `top` + 0.1) from z0 to z1 along x = 0."""
    z, i = z0, 0
    while z < z1:
        for sx in (-1, 1):
            r = 1.15 + 0.2 * _hash(i, sx + seed)
            disc(piece, (sx * 1.55 + (_hash(i, 3 + seed) - 0.5) * 0.3, top, z), r, 0.1, segments=8, bevel=0.0)
        z += step
        i += 1


def split_low_islands(m, name, new_name, y_max):
    """
    Move every connected island of piece `name` whose centre lies below `y_max` into a new piece
    `new_name` (same colour / material). Used on W6's moon_arch: its "Frame" piece holds both the
    post porthole rings (y ~4.5) and the board frame (y >= 9.4), so its box spanned the walk-through
    opening and blocked billboard sight lines (W10b, tests/billboard-clearance). After the split the
    frame box stays above the opening.
    """
    from snkit.core import Piece

    from models._npc_rig import _island_centre, _islands, _subset

    piece = m.pieces[name]
    low, high = set(), set()
    for faces in _islands(piece.bm):
        (low if _island_centre(piece.bm, faces).y < y_max else high).update(faces)  # Roblox axes
    if not low or not high:
        return
    split = Piece(new_name, piece.color, piece.material, piece.tinted, piece.transparency)
    split.bm.free()
    split.bm = _subset(piece.bm, low)
    keep = _subset(piece.bm, high)
    piece.bm.free()
    piece.bm = keep
    m.pieces[new_name] = split


def ringed_planet(body, ring, center, radius, tilt=22.0, segments=12):
    """Toy planet with a flat tilted ring (body + ring pieces), centred on `center`."""
    ellipsoid(body, center, (radius, radius, radius), rings=max(5, segments // 2), segments=segments)
    revolve(ring, [(radius * 1.35, -0.05), (radius * 1.85, -0.05), (radius * 1.85, 0.05), (radius * 1.35, 0.05)], center=center, segments=segments + 4, closed=True, rot=rot_z(tilt))


# ------------------------------------------------------------------------------------------------
# M5 base: floor + entry arch
# ------------------------------------------------------------------------------------------------

DOME_Z = 50.0  # slot z of the lab dome centre (layout DOME)
PLAZA_R = 14.0


def moon_floor(key, stripe_a, stripe_b, craters, rocks, crystals, path_end, plaza=None, budget=4000):
    """
    Shared Moon area ground (slot-origin pivot): two-tone stud stripes, craters, round chrome stepping
    tiles from the road to `path_end`, an optional round plaza (centre z, radius; top T + 0.06), a low
    lumpy moon-rock wall on the sides (z 20..70) and back with violet caps, rocks and crystal clusters.
    craters: [(x, z, r)]; rocks: [(x, z, s)]; crystals: [(x, z, scale)].
    """
    m = Model(key, SLOT_PIVOT, budget=budget)
    ga = m.piece("Ground", stripe_a)
    gb = m.piece("GroundB", stripe_b)
    tiles = m.piece("Tiles", CHROME)
    plaza_p = m.piece("Plaza", CHROME_SHADE)
    rim = m.piece("CraterRims", MOON_ROCK)
    pit = m.piece("CraterFloors", MOON_DARK)
    wall = m.piece("Wall", MOON_ROCK)
    cap = m.piece("WallCaps", VIOLET)
    rock = m.piece("Rocks", MOON_DARK)
    cry_a = m.piece("Crystals", VIOLET)
    cry_b = m.piece("CrystalGlow", STAR_GLOW, material="Neon")
    lot_stripes(ga, gb, -SLOT_W / 2, SLOT_W / 2, 0.0, SLOT_D, stripe=13.0, top=T, along="z")
    round_tiles(tiles, 1.6, path_end)
    if plaza is not None:
        disc(plaza_p, (0, T, plaza[0]), plaza[1], 0.06, segments=28, bevel=0.0)
    for x, z, r in craters:
        crater(rim, pit, (x, T, z), r)
    wh = 2.0
    for x0, x1 in ((-52, -26), (-26, 0), (0, 26), (26, 52)):
        block(wall, ((x0 + x1) / 2, T + wh / 2, SLOT_D - 0.7), (x1 - x0, wh, 1.4), bevel=0.5)
        block(cap, ((x0 + x1) / 2, T + wh + 0.15, SLOT_D - 0.7), (x1 - x0 - 0.6, 0.3, 1.6), bevel=0.1)
    for sx in (-1, 1):
        x = sx * (SLOT_W / 2 - 0.7)
        for z0, z1 in ((20.0, 45.0), (45.0, SLOT_D - 1.4)):
            block(wall, (x, T + wh / 2, (z0 + z1) / 2), (1.4, wh, z1 - z0), bevel=0.5)
            block(cap, (x, T + wh + 0.15, (z0 + z1) / 2), (1.6, 0.3, z1 - z0 - 0.6), bevel=0.1)
    for k, (x, z, s) in enumerate(rocks):
        moon_rock(rock, (x, T + 0.72 * 0.8 * s, z), (s, 0.8 * s, s), seed=k * 3 + 1)
    for k, (x, z, s) in enumerate(crystals):
        crystal_cluster(cry_a, cry_b, (x, T, z), scale=s, seed=k * 5 + 2)
    return m


def build_floor():
    """Star Lab ground: lilac / grey stripes, craters, chrome tiles to a plaza (r 14) round the dome."""
    return moon_floor(
        "M5_Floor",
        MOON_LILAC,
        MOON_GREY,
        craters=((12.5, 39.0, 2.4), (-12.5, 39.0, 2.0), (47.0, 22.0, 2.2), (-47.0, 22.5, 2.6), (22.0, 66.0, 1.8), (-22.0, 66.5, 2.2)),
        rocks=((47.5, 44.0, 1.1), (-47.5, 36.0, 1.0), (10.0, 66.5, 0.9)),
        crystals=((46.0, 63.5, 1.1), (-46.0, 63.5, 1.2)),
        path_end=DOME_Z - PLAZA_R - 1.3,
        plaza=(DOME_Z, PLAZA_R),
    )


def build_entry_arch():
    """'STAR LAB' arch: W6's shared moon_arch (capsule posts, double-sided letters, R17), wide gate."""
    m = moon_arch("M5_EntryArch", "STAR LAB", inner=20.0, planet=MINT_C, ring=SUNNY)
    split_low_islands(m, "Frame", "PortholeRings", 8.0)
    return m


# ------------------------------------------------------------------------------------------------
# Producer: the Lab Dome observatory
# ------------------------------------------------------------------------------------------------

DOME_R = 9.5
DRUM_H = 7.5


def _porthole(glass, frame_piece, center, normal, radius):
    """Round porthole on a curved wall: flat navy glass lens + chrome frame ring (normal = outward)."""
    oriented_ellipsoid(glass, center, (radius, radius, 0.1), normal=normal, rings=4, segments=10)
    n = Vector(normal).normalized()
    pts = circle_points(tuple(Vector(center) + n * 0.05), radius + 0.12, normal=tuple(n), segments=10, up=(0, 1, 0))
    tube(frame_piece, pts, 0.16, sides=4, closed=True)


def build_lab_dome():
    """
    Star Lab (producer): a domed observatory — chrome-white drum on a violet foundation ring with a
    mint band, four navy portholes, a round coral door with a star, a big lilac dome with a navy
    observing slit and a little mint telescope peeking out, a chrome ring walkway round the dome
    foot, an antenna with a small Beacon ball, and two porch Lamps.
    """
    m = Model(
        "M5_LabDome",
        "ground centre (layout: slot (0, 0.5, 50)); door faces -Z (front z = -10.4); dome top y 17.3; Lamp = porch lamps",
        budget=5000,
    )
    base = m.piece("Foundation", VIOLET)
    drum = m.piece("Drum", CHROME)
    band = m.piece("Band", MINT)
    dome = m.piece("Dome", LAVENDER)
    slit = m.piece("Slit", NAVY)
    glass = m.piece("Portholes", NAVY, material="Smooth")
    frames = m.piece("Frames", CHROME_SHADE)
    door = m.piece("Door", CORAL)
    stars = m.piece("Stars", SUNNY)
    scope = m.piece("Scope", MINT)
    antenna = m.piece("Antenna", CHROME_SHADE)
    beacon = m.piece("Beacon", CORAL, material="Neon")
    lamp = m.piece("Lamp", SUN_LIGHT, material="Neon")
    r = DOME_R
    revolve(base, [(0.0, 0.0), (r + 0.9, 0.0), (r + 0.9, 0.7), (r + 0.6, 1.0), (0.0, 1.0)], segments=24)
    revolve(drum, [(0.0, 0.9), (r, 0.9), (r, DRUM_H), (0.0, DRUM_H)], segments=24)
    revolve(band, [(r - 0.1, 5.4), (r + 0.2, 5.4), (r + 0.2, 6.2), (r - 0.1, 6.2)], segments=24, closed=True)
    # Dome: a hemisphere just over the drum + a walkway ring at its foot.
    prof = [(r + 0.05 if i == 0 else (r + 0.05) * math.cos(math.radians(i * 10)), DRUM_H - 0.05 + (r + 0.05) * math.sin(math.radians(i * 10))) for i in range(10)]
    revolve(dome, [(0.0, DRUM_H - 0.05)] + prof, segments=24)
    revolve(frames, [(r - 0.2, DRUM_H - 0.1), (r + 0.75, DRUM_H - 0.1), (r + 0.75, DRUM_H + 0.4), (r - 0.2, DRUM_H + 0.4)], segments=24, closed=True)
    # Observing slit: a navy strip over the dome toward -Z (0.08 proud of the dome).
    pts, nrm, wid = [], [], []
    for i in range(9):
        a = math.radians(20 + i * 8)
        n = Vector((0.0, math.sin(a), -math.cos(a)))
        pts.append(tuple(Vector((0.0, DRUM_H, 0.0)) + n * (r + 0.13)))
        nrm.append(tuple(n))
        wid.append(2.4)
    ribbon(slit, pts, nrm, wid, thick=0.16)
    # Little telescope peeking out of the slit, tilted up toward -Z.
    s0 = Vector((0.0, DRUM_H + 5.5, -5.0))
    s1 = s0 + Vector((0.0, 2.6, -3.2))
    cylinder(scope, tuple(s0), tuple(s1), 0.75, segments=10, radius_b=0.85)
    revolve(frames, [(0.65, -0.12), (0.95, -0.12), (0.95, 0.12), (0.65, 0.12)], center=tuple(s1), segments=10, closed=True, rot=rot_x(51))
    # Door: round coral door proud of the drum, chrome frame ring, a sunny star, a step.
    dz = -r - 0.45
    revolve(door, [(0.0, -0.5), (2.2, -0.5), (2.2, 0.5), (0.0, 0.5)], center=(0, 3.4, dz), segments=16, rot=rot_x(90))
    revolve(frames, [(2.1, -0.6), (2.6, -0.6), (2.6, 0.6), (2.1, 0.6)], center=(0, 3.4, dz), segments=16, closed=True, rot=rot_x(90))
    star_plate(stars, (0, 3.6, dz - 0.62), 0.9, thickness=0.2)
    block(base, (0, 0.55, dz - 1.6), (5.0, 1.1, 2.0), bevel=0.3)
    # Portholes (sides and back) on the drum.
    for deg in (-45.0, -135.0, 30.0, 150.0):
        a = math.radians(deg)
        n = (math.cos(a), 0.0, math.sin(a))
        _porthole(glass, frames, (n[0] * (r + 0.02), 4.0, n[2] * (r + 0.02)), n, 1.2)
    # Antenna on the dome's back shoulder with a small blinking-looking beacon ball.
    a0 = Vector((3.2, DRUM_H + 8.5, 3.6))
    cylinder(antenna, tuple(a0 - Vector((0, 0.6, 0))), tuple(a0 + Vector((0, 3.4, 0))), 0.16, segments=6)
    ellipsoid(antenna, tuple(a0 + Vector((0, 1.6, 0))), (0.9, 0.12, 0.9), rings=3, segments=10)
    ellipsoid(beacon, tuple(a0 + Vector((0, 3.7, 0))), (0.38, 0.38, 0.38), rings=4, segments=8)
    # Porch lamps on short posts beside the door step.
    for sx in (-1, 1):
        x = sx * 3.6
        cylinder(antenna, (x, 0, dz - 1.2), (x, 3.2, dz - 1.2), 0.18, segments=6)
        ellipsoid(lamp, (x, 3.55, dz - 1.2), (0.42, 0.42, 0.42), rings=4, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# M5 props
# ------------------------------------------------------------------------------------------------


def build_star_jars():
    """
    Star Jars: a chrome two-shelf rack with six glass jars, each holding a little glowing sunny star
    (Smooth), coral lids, a big star on top and a double-sided "STARS" sign.
    """
    m = Model("M5_StarJars", "ground centre; shelf faces -Z (front z = -0.9)", budget=2500)
    rack = m.piece("Rack", CHROME_SHADE)
    shelves = m.piece("Shelves", VIOLET)
    jars = m.piece("Jars", GLASS_TINT, material="Glass", transparency=0.45)
    stars = m.piece("JarStars", SUN_LIGHT, material="Smooth")
    lids = m.piece("Lids", CORAL, material="StudsSmall")
    big = m.piece("BigStar", SUNNY)
    sign = m.piece("Sign", NAVY)
    letters = m.piece("Letters", SUNNY, material="Smooth")
    w, d = 6.4, 1.8
    for sx in (-1, 1):
        for sz in (-1, 1):
            cylinder(rack, (sx * (w / 2 - 0.3), 0, sz * (d / 2 - 0.3)), (sx * (w / 2 - 0.3), 5.8, sz * (d / 2 - 0.3)), 0.24, segments=6)
    for y in (0.6, 2.95, 5.35):
        block(shelves, (0, y, 0), (w - 0.2, 0.3, d - 0.1), bevel=0.1)
    for row, y in enumerate((0.75, 3.1)):
        for k, x in enumerate((-1.9, 0.0, 1.9)):
            cylinder(jars, (x, y, 0), (x, y + 1.6, 0), 0.62, segments=10)
            cylinder(lids, (x, y + 1.6, 0), (x, y + 1.85, 0), 0.5, segments=10)
            star_plate(stars, (x, y + 0.8, 0), 0.42, thickness=0.22, up=(math.sin(0.4 * (row + k)), math.cos(0.4 * (row + k)), 0))
    star_plate(big, (1.6, 6.8, 0), 1.0, thickness=0.45)
    block(sign, (-1.2, 6.6, 0), (3.8, 1.2, 0.3), bevel=0.08)
    bar(rack, (-1.2, 5.5, 0), (-1.2, 6.05, 0), 0.25)
    text_both_at(letters, "STARS", -1.2, 6.6, -0.15, 0.15, 0.11, 0.1)
    return m


def build_big_telescope():
    """
    Big Telescope: a round violet platform, a chrome fork mount on a turret, a huge chrome-white tube
    with mint / coral bands tilted 40 deg up toward -X (side-on to the road), a navy glass lens at the
    sky end, a finder scope, the eyepiece at the low end and a little ladder up to it.
    """
    m = Model("M5_BigTelescope", "ground centre of the platform; tube rises toward -X; lens top y ~20", budget=3500)
    platform = m.piece("Platform", VIOLET)
    mount = m.piece("Mount", CHROME_SHADE)
    tube_p = m.piece("Tube", CHROME)
    mint = m.piece("BandsMint", MINT)
    coral = m.piece("BandsCoral", CORAL)
    lens = m.piece("Lens", NAVY, material="Glass", transparency=0.2)
    ladder_p = m.piece("Ladder", SUNNY)
    disc(platform, (0, 0, 0), 5.0, 0.7, segments=18, bevel=0.2)
    revolve(mount, [(0.0, 0.6), (2.4, 0.6), (2.0, 3.2), (1.6, 3.6), (0.0, 3.6)], segments=14)
    pivot = Vector((0.0, 7.0, 0.0))
    for sz in (-1, 1):
        block(mount, (0, 5.2, sz * 1.95), (1.4, 4.0, 0.5), bevel=0.15)
    cylinder(mount, (0, pivot.y, -2.3), (0, pivot.y, 2.3), 0.5, segments=10)
    d = Vector((-math.cos(math.radians(40)), math.sin(math.radians(40)), 0.0))
    low, high = pivot - d * 6.0, pivot + d * 13.0
    cylinder(tube_p, tuple(low), tuple(high), 1.6, segments=16, radius_b=2.1)
    for t, piece in ((0.08, mint), (0.42, coral), (0.86, mint)):
        c = low + (high - low) * t
        rr = 1.6 + 0.5 * t
        cylinder(piece, tuple(c - d * 0.4), tuple(c + d * 0.4), rr + 0.18, segments=16)
    cylinder(lens, tuple(high - d * 0.05), tuple(high + d * 0.15), 1.95, segments=16)
    revolve(mount, [(2.0, -0.35), (2.45, -0.35), (2.45, 0.35), (2.0, 0.35)], center=tuple(high - d * 0.2), segments=16, closed=True, rot=rot_z(50))
    # Finder scope on top of the tube + eyepiece at the low end.
    up = Vector((math.sin(math.radians(40)), math.cos(math.radians(40)), 0.0))
    f0 = pivot + d * 2.0 + up * 2.1
    cylinder(mint, tuple(f0), tuple(f0 + d * 4.0), 0.45, segments=8)
    for t in (0.2, 0.8):
        bar(mount, tuple(pivot + d * (2.0 + 4.0 * t) + up * 1.5), tuple(pivot + d * (2.0 + 4.0 * t) + up * 1.75), 0.3)
    e0 = low + up * 0.2
    cylinder(coral, tuple(e0), tuple(e0 + Vector((0.6, -0.2, 0.0))), 0.55, segments=8)
    # Little ladder from the platform up toward the eyepiece (on the +X side).
    for sz in (-1, 1):
        bar(ladder_p, (4.2, 0.6, sz * 0.7), (2.8, 3.8, sz * 0.7), 0.18)
    for k in range(4):
        t = (k + 0.5) / 4
        x, y = 4.2 - 1.4 * t, 0.6 + 3.2 * t
        bar(ladder_p, (x, y, -0.7), (x, y, 0.7), 0.14)
    return m


MOBILE_TOP = 15.0
MOBILE_R = 5.2


def build_planet_mobile():
    """
    Planet Mobile: a chrome pole on a violet base with a hub and three crossing arms (six tips); each
    tip hangs a toy planet on a string, in colour PAIRS on opposite tips, and a little smiling sun sits
    on top of the hub. Every Twirl* piece (arms, strings, each planet pair, the sun) is point-symmetric
    about the pole, so WorldFx "Twirl" spins them as one group about the pole whichever leads.
    """
    m = Model("M5_PlanetMobile", f"ground centre; pole axis = local Y; Twirl* spin about it; hub y {MOBILE_TOP}", budget=3000)
    base = m.piece("Base", VIOLET)
    pole = m.piece("Pole", CHROME_SHADE)
    arms = m.piece("TwirlArms", CHROME)
    strings = m.piece("TwirlStrings", CHROME_SHADE, material="StudsSmall")
    mint = m.piece("TwirlMint", MINT)
    coral = m.piece("TwirlCoral", CORAL)
    sky = m.piece("TwirlSky", SKY)
    rings = m.piece("TwirlRings", SUNNY)
    sun = m.piece("TwirlSun", SUNNY)
    face = m.piece("TwirlFace", EYE, material="Smooth")
    revolve(base, [(0.0, 0.0), (3.0, 0.0), (3.0, 0.6), (2.2, 1.1), (0.0, 1.1)], segments=16)
    cylinder(pole, (0, 1.0, 0), (0, MOBILE_TOP - 0.4, 0), 0.32, segments=8)
    ellipsoid(arms, (0, MOBILE_TOP, 0), (0.8, 0.55, 0.8), rings=4, segments=8)
    pieces = (mint, coral, sky)
    for k in range(3):
        a = math.radians(k * 60)
        dx, dz = math.cos(a) * MOBILE_R, math.sin(a) * MOBILE_R
        bar(arms, (-dx, MOBILE_TOP, -dz), (dx, MOBILE_TOP, dz), 0.22)
        for s in (-1, 1):
            tip = Vector((s * dx, MOBILE_TOP, s * dz))
            drop = 2.4 + 1.2 * k
            bar(strings, tuple(tip), tuple(tip - Vector((0, drop, 0))), 0.07)
            ellipsoid(arms, tuple(tip), (0.3, 0.3, 0.3), rings=3, segments=6)
            pr = 1.1 - 0.12 * k
            c = tip - Vector((0, drop + pr, 0))
            ellipsoid(pieces[k], tuple(c), (pr, pr, pr), rings=6, segments=10)
            if k == 1:
                revolve(rings, [(pr * 1.35, -0.05), (pr * 1.8, -0.05), (pr * 1.8, 0.05), (pr * 1.35, 0.05)], center=tuple(c), segments=14, closed=True, rot=rot_z(20 * s))
    # Smiling sun on top of the hub (on the axis).
    sc = (0.0, MOBILE_TOP + 1.6, 0.0)
    ellipsoid(sun, sc, (1.2, 1.2, 1.2), rings=6, segments=12)
    for k in range(8):
        a = math.radians(k * 45)
        p = Vector((math.cos(a), math.sin(a), 0.0))
        cylinder(sun, tuple(Vector(sc) + p * 1.1), tuple(Vector(sc) + p * 1.75), 0.24, segments=5, radius_b=0.03)
    for sz in (-1, 1):
        for sx in (-1, 1):
            oriented_ellipsoid(face, (sx * 0.38, sc[1] + 0.25, sz * 1.1), (0.13, 0.17, 0.05), normal=(0, 0, sz), rings=3, segments=6)
    smile(face, sc, (1.2, 1.2, 1.2), pitch=-15.0, width=22.0, depth=8.0, thickness=0.06, steps=5)
    # The back smile: the same arc turned 180 deg about the pole onto +Z, so the face piece stays
    # point-symmetric about the axis (its box centre on the pole, like every Twirl* piece).
    before = set(face.bm.verts)
    smile(face, sc, (1.2, 1.2, 1.2), pitch=-15.0, width=22.0, depth=8.0, thickness=0.06, steps=5)
    from snkit.core import br, rb

    for v in face.bm.verts:
        if v not in before:
            p = Vector(br(v.co))
            v.co = rb((-p.x, p.y, -p.z))
    return m


def build_comet_catcher():
    """
    Comet Catcher: a sunny tripod with a big mint hoop net tilted toward the sky and a cute caught
    comet in it (a smiling sunny star with a pink / coral tail), plus a little coral bucket.
    """
    m = Model("M5_CometCatcher", "ground centre of the tripod; net faces -Z / up", budget=2500)
    legs = m.piece("Tripod", SUNNY)
    hoop = m.piece("Hoop", MINT)
    net = m.piece("Net", CHROME, material="StudsSmall")
    comet = m.piece("Comet", SUNNY)
    tail = m.piece("Tail", PINK)
    tail2 = m.piece("TailCoral", CORAL)
    face = m.piece("Face", EYE, material="Smooth")
    hub = Vector((0.0, 6.0, 0.6))
    for k in range(3):
        a = math.radians(90 + k * 120)
        foot = Vector((math.cos(a) * 2.4, 0.0, math.sin(a) * 2.4 + 0.6))
        bar(legs, tuple(foot), tuple(hub), 0.28)
    ellipsoid(legs, tuple(hub), (0.6, 0.6, 0.6), rings=4, segments=8)
    # Hoop: ring of radius 3.2 centred above the hub, its plane tilted 35 deg back (faces -Z / up).
    tilt = rot_x(-35)
    hc = hub + Vector((0.0, 3.6, -0.4))
    revolve(hoop, [(3.0, -0.18), (3.4, -0.18), (3.4, 0.18), (3.0, 0.18)], center=tuple(hc), segments=20, closed=True, rot=tilt @ rot_x(90))
    bar(legs, tuple(hub), tuple(hc - tilt @ Vector((0, 3.0, 0))), 0.25)
    for k in range(5):
        x = -2.4 + 1.2 * k
        h = math.sqrt(max(3.0**2 - x**2, 0.1))
        bar(net, tuple(hc + tilt @ Vector((x, -h, 0.25))), tuple(hc + tilt @ Vector((x, h, 0.25))), 0.06)
        bar(net, tuple(hc + tilt @ Vector((-h, x, 0.25))), tuple(hc + tilt @ Vector((h, x, 0.25))), 0.06)
    # The comet: a star with a face, in the net, its two-tone tail curling out to one side.
    cc = hc + tilt @ Vector((0.0, 0.0, -0.6))
    star_plate(comet, tuple(cc), 1.6, thickness=0.9, normal=tuple(tilt @ Vector((0, 0, -1))), up=tuple(tilt @ Vector((0, 1, 0))))
    n = tilt @ Vector((0, 0, -1))
    for sx in (-1, 1):
        oriented_ellipsoid(face, tuple(cc + n * 0.48 + tilt @ Vector((sx * 0.4, 0.25, 0))), (0.16, 0.2, 0.05), normal=tuple(n), rings=3, segments=6)
    path = [cc + tilt @ Vector((1.0 + 0.9 * i, 0.4 * math.sin(i * 0.9), 0.4)) for i in range(5)]
    tube(tail, [tuple(p) for p in path], 0.5, sides=6, radii=[0.7, 0.6, 0.48, 0.34, 0.15])
    path2 = [cc + tilt @ Vector((1.2 + 0.8 * i, -0.5 - 0.3 * math.sin(i), 0.5)) for i in range(4)]
    tube(tail2, [tuple(p) for p in path2], 0.4, sides=6, radii=[0.45, 0.36, 0.25, 0.1])
    return m


def build_robot_arm():
    """
    Robot Arm: a friendly chunky arm on a navy turntable — coral ball joints, chrome-white upper arm
    and forearm, a mint two-finger gripper holding a little sunny star — plus a big candy button box.
    """
    m = Model("M5_RobotArm", "ground centre of the turntable; the arm reaches toward -Z / up", budget=2500)
    base = m.piece("Base", NAVY)
    joints = m.piece("Joints", CORAL)
    arm = m.piece("Segments", CHROME)  # not "Arm": that name is a WorldFx swing row
    grip = m.piece("Gripper", MINT)
    star_p = m.piece("Star", SUNNY)
    box = m.piece("ButtonBox", VIOLET)
    buttons = m.piece("Buttons", SUNNY, material="StudsSmall")
    revolve(base, [(0.0, 0.0), (3.0, 0.0), (3.0, 0.8), (2.4, 1.6), (1.4, 2.0), (0.0, 2.0)], segments=16)
    shoulder = Vector((0.0, 3.0, 0.6))
    elbow = Vector((0.0, 8.6, 2.2))
    wrist = Vector((0.0, 9.8, -3.0))
    cylinder(arm, (0, 1.8, 0.4), tuple(shoulder), 1.0, segments=10)
    ellipsoid(joints, tuple(shoulder), (1.4, 1.4, 1.4), rings=6, segments=10)
    cylinder(arm, tuple(shoulder), tuple(elbow), 0.95, segments=10, radius_b=0.8)
    ellipsoid(joints, tuple(elbow), (1.15, 1.15, 1.15), rings=6, segments=10)
    cylinder(arm, tuple(elbow), tuple(wrist), 0.75, segments=10, radius_b=0.65)
    ellipsoid(joints, tuple(wrist), (0.85, 0.85, 0.85), rings=5, segments=8)
    d = (wrist - elbow).normalized()
    for sx in (-1, 1):
        f0 = wrist + d * 0.6 + Vector((sx * 0.45, 0, 0))
        bar(grip, tuple(f0), tuple(f0 + d * 1.2 + Vector((sx * 0.25, -0.2, 0))), 0.3)
    star_plate(star_p, tuple(wrist + d * 2.0 + Vector((0, -0.2, 0))), 0.9, thickness=0.4, normal=(0, 0, -1))
    # Button box beside the turntable.
    block(box, (3.6, 1.0, -1.6), (1.8, 2.0, 1.4), bevel=0.25)
    for k, x in enumerate((3.15, 3.6, 4.05)):
        ellipsoid(buttons, (x, 2.05, -1.6), (0.2, 0.12, 0.2), rings=3, segments=6)
    return m


def _space_plant(stem, bulb, base, height, seed):
    """Cute space plant: a curly mint stem with a round violet bulb and two leaf balls."""
    bx, by, bz = base
    pts = []
    for i in range(5):
        t = i / 4
        pts.append((bx + 0.35 * math.sin(t * 3 + seed), by + height * t, bz + 0.35 * math.cos(t * 3 + seed)))
    tube(stem, pts, 0.14, sides=5)
    ellipsoid(bulb, pts[-1], (0.55, 0.62, 0.55), rings=5, segments=8)
    for s in (-1, 1):
        ellipsoid(stem, (bx + s * 0.35, by + height * 0.45, bz), (0.3, 0.14, 0.18), rings=3, segments=6)


def build_moon_garden():
    """
    Moon Garden: two chrome-rimmed planters of lilac soil with cute space plants (curly mint stems,
    violet bulbs), little sunny glow berries, a glass mini-dome over one bed, and a coral watering can.
    """
    m = Model("M5_MoonGarden", "ground centre between the two planters; front -Z", budget=2500)
    rim = m.piece("Planters", CHROME)
    soil = m.piece("Soil", MOON_DARK)
    stem = m.piece("Stems", MINT)
    bulb = m.piece("Bulbs", VIOLET)
    berry = m.piece("Berries", SUNNY, material="StudsSmall")
    dome = m.piece("GlassDome", GLASS_TINT, material="Glass", transparency=0.5)
    can = m.piece("WateringCan", CORAL)
    for k, x in enumerate((-2.6, 2.6)):
        block(rim, (x, 0.5, 0), (4.4, 1.0, 3.4), bevel=0.25)
        block(soil, (x, 1.02, 0), (3.8, 0.1, 2.8), bevel=0.0)
        for j, (dx, dz) in enumerate(((-1.1, -0.6), (0.2, 0.7), (1.2, -0.5))):
            _space_plant(stem, bulb, (x + dx, 1.05, dz), 1.6 + 0.6 * _hash(k, j), seed=k * 3 + j)
        for j in range(4):
            ellipsoid(berry, (x - 1.4 + 0.9 * j, 1.25, 1.0 - 0.2 * (j % 2)), (0.2, 0.2, 0.2), rings=3, segments=5)
    revolve(dome, [(0.0, 3.9), (0.8, 3.75), (1.5, 3.2), (1.85, 2.2), (1.9, 1.1), (0.0, 1.1)], center=(2.6, 0, 0), segments=14)
    # Watering can at the front-left.
    cylinder(can, (-5.6, 0.0, -1.8), (-5.6, 1.2, -1.8), 0.55, segments=8)
    bar(can, (-5.2, 0.5, -1.8), (-4.3, 1.3, -1.8), 0.16)
    bar(can, (-5.9, 1.4, -1.8), (-5.3, 1.4, -1.8), 0.12)
    return m


NOVA_SKIN = (255, 164, 214)  # Dr. Nova: friendly pink alien


def lab_coat(coat, front, a, lapel=None):
    """
    Lab coat over a toon_biped body: a coat shell 1.04x the body (it contains the body, so no shared
    face, R18), a cream shirt oval showing through the open front and optional lapel tubes.
    """
    from models._critter_kit import surface

    bc, br = a["body_c"], a["body"]
    sr = (br[0] * 1.04, br[1] * 1.04, br[2] * 1.04)
    ellipsoid(coat, bc, sr, rings=8, segments=12)
    oriented_ellipsoid(front, (0.0, bc[1] - br[1] * 0.08, bc[2] - sr[2] * 0.86), (br[0] * 0.48, br[1] * 0.6, 0.32), normal=(0, 0, -1), rings=5, segments=10)
    if lapel is not None:
        for side in (-1, 1):
            pts = []
            for pitch, yaw in ((44, 26), (22, 30), (0, 31), (-22, 27)):
                p, n = surface(bc, sr, side * yaw, pitch)
                pts.append(tuple(p + n * 0.04))
            tube(lapel, pts, 0.09, sides=4)


def build_dr_nova():
    """
    Dr. Nova (Manager): a round pink alien scientist on W6's shared Moon body (toon_biped) in a white
    lab coat (cream shirt, lapels), big glossy eyes behind round chrome glasses, two springy antennae
    with sunny star tips, holding up a glass beaker of bubbly mint potion, beside a lab bench with a
    test-tube rack. Figure at the model origin, yaw 0. R30 rig: the beaker rides ArmR (raised),
    ArmL is the relaxed wave arm; face / glasses / antennae ride the Head; coat and shirt the Torso.
    """
    from models._critter_kit import eyes
    from models._npc_rig import rig_split

    m = Model("M5_DrNova", "ground centre between the feet; Dr. Nova faces -Z; lab bench at local +X", budget=3000)
    skin = m.piece("Skin", NOVA_SKIN, material="Smooth")
    coat = m.piece("Coat", CHROME)
    sleeves = m.piece("Sleeves", CHROME)  # arms + legs (classified per limb by rig_split)
    shirt = m.piece("Shirt", (250, 244, 226), material="Smooth")
    boots = m.piece("Boots", NAVY, material="Smooth")
    face = m.piece("Face", EYE, material="Smooth")
    shine = m.piece("Shine", SHINE, material="Smooth")
    glasses = m.piece("Glasses", CHROME_SHADE, material="StudsSmall")
    antenna = m.piece("Antennae", VIOLET, material="Smooth")
    tips = m.piece("AntennaTips", SUNNY, material="Smooth")
    beaker = m.piece("Beaker", GLASS_TINT, material="Glass", transparency=0.4)
    potion = m.piece("Potion", MINT_C, material="Smooth")
    bench = m.piece("Bench", VIOLET)
    top = m.piece("BenchTop", CHROME_SHADE)
    tubes = m.piece("TestTubes", PINK, material="Smooth")
    a = toon_biped(
        {"body": skin, "head": skin, "limbs": sleeves, "hands": skin, "feet": boots},
        body=(1.3, 1.25, 1.15),
        head=(1.15, 1.02, 1.05),
        leg_h=1.3,
        arm_pose={"left": (12.0, 22.0), "right": (8.0, 128.0)},
    )
    lab_coat(coat, shirt, a, lapel=shirt)
    hc, hr = a["head"], a["head_r"]
    eyes(face, shine, hc, hr, yaw=26.0, pitch=10.0, size=0.26, tall=1.25)
    smile(face, hc, hr, pitch=-24.0, width=22.0, depth=8.0, thickness=0.06, steps=6)
    from models._critter_kit import surface

    for side in (-1, 1):
        p, n = surface(hc, hr, side * 26.0, 10.0)
        pts = circle_points(tuple(p + n * 0.22), 0.42, normal=tuple(n), segments=10, up=(0, 1, 0))
        tube(glasses, pts, 0.07, sides=4, closed=True)
        bp, _ = surface(hc, hr, side * 32.0, 62.0)
        tube(antenna, [tuple(bp), tuple(bp + Vector((side * 0.25, 0.7, 0.0))), tuple(bp + Vector((side * 0.55, 1.2, -0.1)))], 0.08, sides=5)
        star_plate(tips, tuple(bp + Vector((side * 0.62, 1.55, -0.1))), 0.36, thickness=0.18)
    p0, _ = surface(hc, hr, -9.0, 10.0)
    p1, _ = surface(hc, hr, 9.0, 10.0)
    bar(glasses, tuple(p0 + Vector((0, 0, -0.22))), tuple(p1 + Vector((0, 0, -0.22))), 0.07)
    # Beaker held up in the right hand: glass flask + mint potion + bubbles.
    hx, hy, hz = a["hands"]["right"]
    bc = (hx, hy + 0.9, hz - 0.1)
    revolve(beaker, [(0.0, -0.55), (0.55, -0.55), (0.6, 0.1), (0.25, 0.45), (0.25, 0.85), (0.0, 0.85)], center=bc, segments=10)
    revolve(potion, [(0.0, -0.5), (0.5, -0.5), (0.54, 0.05), (0.0, 0.05)], center=bc, segments=10)
    for k in range(2):
        ellipsoid(potion, (bc[0] + 0.1 * (k * 2 - 1), bc[1] + 0.35 + 0.3 * k, bc[2]), (0.12, 0.12, 0.12), rings=3, segments=5)
    # Lab bench at local +X: four legs, a chrome top, a test-tube rack with three pink tubes.
    tx = 3.9
    for sx in (-1, 1):
        for sz in (-1, 1):
            cylinder(bench, (tx + sx * 0.9, 0.0, sz * 0.75), (tx + sx * 0.9, 2.5, sz * 0.75), 0.16, segments=5)
    block(top, (tx, 2.6, 0), (2.4, 0.24, 2.0), bevel=0.06)
    block(bench, (tx, 2.95, 0.2), (1.6, 0.5, 0.6), bevel=0.08)
    for k in range(3):
        cylinder(tubes, (tx - 0.5 + 0.5 * k, 2.75, 0.2), (tx - 0.5 + 0.5 * k, 3.75, 0.2), 0.16, segments=6)
    rig_split(
        m,
        toon_bones(a),
        static=("Bench", "BenchTop", "TestTubes"),
        assign={
            "Coat": "Torso", "Shirt": "Torso", "Face": "Head", "Shine": "Head", "Glasses": "Head", "Antennae": "Head",
            "AntennaTips": "Head", "Beaker": "ArmR", "Potion": "ArmR",
        },
    )
    return m


def build_mission_banners():
    """
    Mission Banners: two chrome poles flanking the walkway, star finials, tall double-sided navy
    banners (a sunny star on one, a coral rocket on the other) and a sagging bunting string between
    the pole tops (Pennant* pieces sway: existing WorldFx row; the rope is the pivot line).
    """
    m = Model("M5_MissionBanners", "ground centre of the walkway; poles at x = +-9; banners face -Z; Pennant* sway", budget=2500)
    pole = m.piece("Poles", CHROME)
    finial = m.piece("Finials", SUNNY)
    cloth = m.piece("Banners", NAVY)
    trim = m.piece("BannerTrim", VIOLET)
    emblem = m.piece("Emblems", SUNNY, material="Smooth")
    rocket = m.piece("EmblemRocket", CORAL, material="Smooth")  # not "Rocket*" (WorldFx shake row)
    rope = m.piece("PennantRope", CHROME_SHADE, material="StudsSmall")
    fa = m.piece("PennantMint", MINT, material="StudsSmall")
    fb = m.piece("PennantViolet", LAVENDER, material="StudsSmall")
    fc = m.piece("PennantCoral", CORAL, material="StudsSmall")
    px, ph = 9.0, 15.0
    for sx in (-1, 1):
        x = sx * px
        disc(trim, (x, 0, 0), 0.8, 0.4, segments=10, bevel=0.1)
        cylinder(pole, (x, 0.3, 0), (x, ph, 0), 0.34, segments=8)
        bar(pole, (x, ph - 0.9, 0), (x + sx * 3.6, ph - 0.9, 0), 0.3)
        star_plate(finial, (x, ph + 0.9, 0), 0.9, thickness=0.4)
        bx = x + sx * 2.0
        top, bottom = ph - 1.2, ph - 8.6
        outline = [(bx - 1.5, top), (bx + 1.5, top), (bx + 1.5, bottom), (bx, bottom + 0.9), (bx - 1.5, bottom)]
        prism(cloth, [(x_, y_, 0.0) for x_, y_ in outline], (0, 0, 1), 0.2)
        block(trim, (bx, top + 0.1, 0), (3.2, 0.3, 0.32), bevel=0.06)
        cy = (top + bottom) / 2 + 0.6
        for sz in (-1, 1):
            if sx > 0:
                star_plate(emblem, (bx, cy, sz * 0.14), 1.0, thickness=0.06, normal=(0, 0, sz))
            else:
                n = (0, 0, sz)
                oriented_ellipsoid(rocket, (bx, cy + 0.3, sz * 0.13), (0.45, 1.1, 0.05), normal=n, rings=4, segments=8)
                for fx in (-1, 1):
                    prism(rocket, [(bx + fx * 0.35, cy - 0.5, sz * 0.13), (bx + fx * 0.85, cy - 1.0, sz * 0.13), (bx + fx * 0.35, cy - 1.0, sz * 0.13)], (0, 0, 1), 0.08)
    a, b = Vector((-px + 0.35, ph - 0.4, 0)), Vector((px - 0.35, ph - 0.4, 0))
    cable(rope, tuple(a), tuple(b), 1.4, thick=0.09, steps=8)
    flags = (fa, fb, fc)
    for k in range(9):
        t = (k + 1) / 10
        p = a.lerp(b, t)
        p.y -= 1.4 * 4 * t * (1 - t)
        prism(flags[k % 3], [(p.x - 0.55, p.y - 0.05, 0.0), (p.x + 0.55, p.y - 0.05, 0.0), (p.x, p.y - 1.2, 0.0)], (0, 0, 1), 0.08)
    return m


BUILDERS = {
    "M5_Floor": build_floor,
    "M5_EntryArch": build_entry_arch,
    "M5_LabDome": build_lab_dome,
    "M5_StarJars": build_star_jars,
    "M5_BigTelescope": build_big_telescope,
    "M5_PlanetMobile": build_planet_mobile,
    "M5_CometCatcher": build_comet_catcher,
    "M5_RobotArm": build_robot_arm,
    "M5_MoonGarden": build_moon_garden,
    "M5_DrNova": build_dr_nova,
    "M5_MissionBanners": build_mission_banners,
}
