"""
moon_area06.py — Moon Base area M6 "Star Reactor" (R69-R71 spec §2.2, owner R70), the Moon FINALE:
a friendly smiling mini-sun inside a chrome ring cage on a big stepped pedestal (producer), two
tilted orbit rings with planets circling it, beam towers feeding it soft light beams, glowing
plasma pipes, coolant pumps with spinning flywheels, a swirling nebula core under a glass dome, a
sparkly "star water" meteor fall, a floating star-tile bridge from a moon-rock spire to the pedestal
deck, a galaxy crown of stars on top of the cage, Commander Lux (manager) — and, the finale, a
GOLDEN ASTRONAUT STATUE standing on top of the sun's cage, waving at the whole Moon.

Placement: src/shared/Config/Worlds/Moon/Layouts/Area06.luau (slot-local; docs/areas-art.md
"Moon M5-M6"). Shared Moon helpers: W6's models.moon_area01 (moon_arch, moon_rock, toon_biped) and
W8's moon_area05.py (palette names, moon_floor, crystal, star_plate). Glow (owner R19): the sun, beams, plasma and star water are
Smooth / Glass light colours, never big Neon.

Models (key: pivot / notes)                                                   build key
    M6_Floor           SLOT ORIGIN pivot (layout cf = identity); top y = 0.5          base
    M6_EntryArch       ground centre between the pillars; "STAR REACTOR"             base
    M6_StarCore        PRODUCER: pedestal ground centre (slot (0, 0.5, 48)); deck    M6_StarCore
                       y 9; sun centre y 23.5 (CoreSun: pulsing light); cage top y 36;
                       top platform y 37 = M6_GoldenAstronaut pivot
    M6_PlasmaPipes     front centre between the plasma tanks (slot (0, 0.5, 23))      M6_PlasmaPipes
    M6_OrbitRings      SAME pivot as the star core; Carousel* spin about Y           M6_OrbitRings
    M6_BeamTowers      SAME pivot as the star core; towers at local (+-26, 0, 14)    M6_BeamTowers
    M6_CoolantPumps    ground centre; WheelFly* spin X (placed twice)                M6_CoolantPumps
    M6_NebulaCore      ground centre of the dome; Twirl* swirl + Core orb            M6_NebulaCore
    M6_MeteorFalls     ground centre of the pool; cliff toward +Z; StarFall*         M6_MeteorFalls
    M6_StarBridge      spire foot (slot (-44, 0.5, 30)); tiles land on the deck     M6_StarBridge
    M6_GalaxyCrown     SAME pivot as the star core; circlet on the cage top          M6_GalaxyCrown
    M6_CommanderLux    Manager (see build_commander_lux)                              M6_CommanderLux
    M6_GoldenAstronaut FINALE: top platform centre (star-core local (0, 37, 0))       M6_GoldenAstronaut

Budgets: fully built M6 <= 34k triangles; each model <= 6k / 24 pieces; height budget 140.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import Model
from snkit.kit import block, disc
from snkit.shapes import bar, cylinder, ellipsoid, loft, revolve, rot_x, rot_y, rot_z

from models._critter_kit import oriented_ellipsoid, smile, surface, tube
from models.area04 import _hash
from models.area09 import cable
from models.moon_area05 import (
    CHROME,
    Xf,
    clipboard_helper,
    place_new,
    CHROME_SHADE,
    CORAL,
    EYE,
    GLASS_TINT,
    LAVENDER,
    MINT,
    MOON_DARK,
    MOON_ROCK,
    NAVY,
    PINK,
    SHINE,
    SKY,
    SUN_LIGHT,
    SUNNY,
    VIOLET,
    crystal,
    moon_floor,
    split_low_islands,
    star_plate,
)
from models.moon_area01 import moon_arch, moon_rock, toon_biped, toon_bones

GOLD = (255, 200, 52)
GOLD_LIGHT = (255, 228, 128)
GOLD_DARK = (216, 152, 36)
NEBULA_PINK = (255, 150, 210)
STAR_WATER = (176, 212, 255)  # sparkly "star water" (Smooth light blue)

# ------------------------------------------------------------------------------------------------
# Star core geometry (shared by StarCore / OrbitRings / BeamTowers / GalaxyCrown / StarBridge /
# PlasmaPipes / the statue, so the separately built pieces always meet). Star-core local frame:
# pedestal ground centre, front -Z.
# ------------------------------------------------------------------------------------------------

CORE_SLOT = (0.0, 48.0)  # slot (x, z) of the star core pivot (layout CORE)
TIER1_R, TIER1_H = 16.0, 3.0  # violet base tier
DECK_R, DECK_Y = 13.0, 9.0  # chrome upper tier; its flat top is the walkable deck
SUN_Y, SUN_R = 23.5, 9.5  # the mini-sun
CAGE_R = 12.5  # cage meridian ring radius (about the sun centre)
TOP_Y = SUN_Y + CAGE_R + 1.0  # top platform surface = statue pivot (37)
ORBIT_R = 17.5
ORBIT_Y = SUN_Y - 8.0  # orbit plane under the sun's face (Studio check: at SUN_Y the rings crossed its eyes)
SPIRE_SLOT = (-44.0, 30.0)  # star bridge spire foot (layout SPIRE)
BRIDGE_A = math.degrees(math.atan2(SPIRE_SLOT[1] - CORE_SLOT[1], SPIRE_SLOT[0] - CORE_SLOT[0])) % 360.0
TOWER_X, TOWER_Z = 26.0, 14.0  # beam towers at star-core local (+-26, 0, 14)
TOWER_H = 34.0
TANK_X, PIPES_SLOT_Z = 11.0, 23.0  # plasma tanks at slot (+-11, 23): clear of the finale pad board (0, 6.5, 14)


def _ring(piece, center, radius, width, depth, rot, segments=24):
    """Square-section ring about `center`, its axis = rot @ +Y (cage bars, orbit rings, bands)."""
    revolve(piece, [(radius - width / 2, -depth / 2), (radius + width / 2, -depth / 2), (radius + width / 2, depth / 2), (radius - width / 2, depth / 2)], center=center, segments=segments, closed=True, rot=rot)


# ------------------------------------------------------------------------------------------------
# M6 base: floor + entry arch
# ------------------------------------------------------------------------------------------------


def build_floor():
    """Star Reactor ground: deeper lilac stripes, craters, chrome tiles to the pedestal front."""
    return moon_floor(
        "M6_Floor",
        (198, 186, 234),
        (178, 172, 208),
        craters=((20.0, 38.0, 2.2), (-22.0, 40.0, 2.0), (47.5, 40.5, 2.0), (-40.0, 64.0, 1.8), (16.0, 66.0, 1.8)),
        rocks=((49.0, 21.5, 1.2), (-49.0, 21.5, 1.3), (49.0, 46.0, 0.9)),
        crystals=((-47.0, 63.5, 1.2), (8.0, 66.5, 0.9)),
        path_end=CORE_SLOT[1] - TIER1_R - 1.4,
        plaza=None,
    )


def build_entry_arch():
    """
    'STAR / REACTOR' arch: W6's shared moon_arch (two lines, violet board, sunny planets), wide gate.
    The post porthole rings are split out of "Frame" so its box stays above the opening (W10b).
    """
    m = moon_arch("M6_EntryArch", ["STAR", "REACTOR"], inner=20.0, board=VIOLET, planet=SUNNY, ring=CORAL, cell=0.5, budget=5000)
    split_low_islands(m, "Frame", "PortholeRings", 8.0)
    return m


# ------------------------------------------------------------------------------------------------
# Producer: the Star Core
# ------------------------------------------------------------------------------------------------


def build_star_core():
    """
    Star Core (producer): a two-tier pedestal (violet base, chrome upper tier with a mint band and a
    walkable deck at y 9 with a railing, gap where the star bridge lands), a friendly smiling
    mini-sun (CoreSun: Smooth sunny light colour + WorldFx "Core" pulsing light; R19) with blush,
    a halo of rays behind it, a chrome ring cage (base ring + four meridian rings), a gold top
    platform for the Golden Astronaut, and two plasma ports on the pedestal front for the pipes.
    """
    m = Model(
        "M6_StarCore",
        f"pedestal ground centre (layout: slot (0, 0.5, 48)); front -Z; deck y {DECK_Y} r {DECK_R}; sun centre y {SUN_Y} "
        f"r {SUN_R}; top platform y {TOP_Y} (statue pivot); CoreSun = pulsing light",
        budget=6000,
    )
    base = m.piece("BaseTier", VIOLET)
    tier = m.piece("Tier", CHROME)
    band = m.piece("Band", MINT)
    rail = m.piece("Railing", CHROME_SHADE)
    sun = m.piece("CoreSun", SUN_LIGHT, material="Smooth")
    rays = m.piece("Rays", SUNNY)
    face = m.piece("Face", EYE, material="Smooth")
    shine = m.piece("Shine", SHINE, material="Smooth")
    blush = m.piece("Blush", PINK, material="Smooth")
    cage = m.piece("Cage", CHROME_SHADE)
    gold = m.piece("Platform", GOLD)
    ports = m.piece("Ports", CORAL)
    revolve(base, [(0.0, 0.0), (TIER1_R, 0.0), (TIER1_R, TIER1_H - 0.4), (TIER1_R - 0.6, TIER1_H), (0.0, TIER1_H)], segments=32)
    revolve(tier, [(0.0, TIER1_H - 0.05), (DECK_R, TIER1_H - 0.05), (DECK_R, DECK_Y), (0.0, DECK_Y)], segments=32)
    revolve(band, [(DECK_R - 0.1, 5.2), (DECK_R + 0.22, 5.2), (DECK_R + 0.22, 6.2), (DECK_R - 0.1, 6.2)], segments=32, closed=True)
    # Deck railing: posts + a rail ring segment, skipping the bridge landing (+-12 deg).
    gap = math.radians(12.0)
    ab = math.radians(BRIDGE_A)
    prev = None
    for k in range(32):
        a = 2 * math.pi * k / 32
        if abs((a - ab + math.pi) % (2 * math.pi) - math.pi) < gap:
            prev = None
            continue
        p = Vector((math.cos(a) * (DECK_R - 0.4), DECK_Y, math.sin(a) * (DECK_R - 0.4)))
        if k % 2 == 0:
            cylinder(rail, tuple(p), tuple(p + Vector((0, 1.9, 0))), 0.16, segments=5)
        top = p + Vector((0, 1.7, 0))
        if prev is not None:
            bar(rail, tuple(prev), tuple(top), 0.14)
        prev = top
    # Sun + face (front -Z) + blush + rays halo behind it (vertical plane, static).
    sc = Vector((0.0, SUN_Y, 0.0))
    ellipsoid(sun, tuple(sc), (SUN_R, SUN_R, SUN_R), rings=12, segments=20)
    sr = (SUN_R, SUN_R, SUN_R)
    for sx in (-1, 1):
        p, n = surface(tuple(sc), sr, sx * 20.0, 12.0)
        oriented_ellipsoid(face, tuple(p - n * 0.15), (0.9, 1.25, 0.4), normal=tuple(n), rings=5, segments=10)
        oriented_ellipsoid(shine, tuple(p + n * 0.2 + Vector((sx * -0.25, 0.45, 0))), (0.32, 0.32, 0.12), normal=tuple(n), rings=3, segments=6)
        p, n = surface(tuple(sc), sr, sx * 38.0, -12.0)
        oriented_ellipsoid(blush, tuple(p - n * 0.1), (1.1, 0.7, 0.2), normal=tuple(n), rings=3, segments=8)
    smile(face, tuple(sc), (SUN_R, SUN_R, SUN_R), pitch=-18.0, width=24.0, depth=9.0, thickness=0.28, steps=7)
    for k in range(16):
        a = math.radians(k * 22.5)
        p = Vector((math.cos(a), math.sin(a), 0.0))
        cylinder(rays, tuple(sc + p * (SUN_R - 0.4) + Vector((0, 0, 2.6))), tuple(sc + p * (SUN_R + 2.2) + Vector((0, 0, 2.6))), 0.9 if k % 2 == 0 else 0.6, segments=6, radius_b=0.06)
    # Cage: a footlight ring on the deck, a chrome sun-holder cup whose top holds the cage's bottom
    # pole (the four meridian rings meet at (0, SUN_Y - CAGE_R) and (0, SUN_Y + CAGE_R)).
    _ring(cage, (0.0, DECK_Y + 0.35, 0.0), 10.4, 0.8, 0.7, None, segments=32)
    revolve(rail, [(0.0, DECK_Y - 0.05), (3.0, DECK_Y - 0.05), (2.6, DECK_Y + 1.0), (1.6, SUN_Y - CAGE_R + 0.6), (0.0, SUN_Y - CAGE_R + 0.6)], segments=16)
    for k in range(4):
        _ring(cage, tuple(sc), CAGE_R, 0.55, 0.55, rot_y(45.0 * k) @ rot_x(90.0), segments=32)
    # Top platform (gold disc) resting on the cage crown.
    revolve(gold, [(0.0, TOP_Y - 1.1), (2.0, TOP_Y - 1.1), (3.6, TOP_Y - 0.4), (3.6, TOP_Y), (0.0, TOP_Y)], segments=20)
    # Plasma ports on the pedestal front (the pipes start 0.15 in front of them).
    for sx in (-1, 1):
        a = math.atan2(-math.sqrt(TIER1_R**2 - 6.0**2), sx * 6.0)
        z = math.sin(a) * TIER1_R
        block(ports, (sx * 6.0, 1.5, z - 0.4), (2.4, 2.2, 1.6), bevel=0.4)
    return m


def build_orbit_rings():
    """
    Orbit Rings (SAME pivot as the star core): two big chrome rings tilted +-14 deg round the sun's
    lower half (centred on its axis, 8 under its centre, so they frame the chin, never the eyes),
    each with a planet pair on its nodes (equator crossings). Rings and pairs are point-symmetric
    about the vertical axis through the sun, so WorldFx "Carousel" spins every Carousel* piece as one
    group about it.
    """
    m = Model("M6_OrbitRings", f"SAME pivot as M6_StarCore; rings r {ORBIT_R} centred on the sun axis at y {ORBIT_Y}; Carousel* spin Y", budget=3000)
    rings = m.piece("CarouselRings", CHROME)
    mint = m.piece("CarouselMint", MINT)
    coral = m.piece("CarouselCoral", CORAL)
    band = m.piece("CarouselBands", SUNNY)
    sc = (0.0, ORBIT_Y, 0.0)
    # (Tilt 14 deg: the rings stay >= 1.6 studs under the beam-tower beams, R24.)
    # Yaws 45 / 135: at rest no planet sits in front of the sun's face (Studio check: a coral planet
    # on the -Z node read as a clown nose).
    for k, (yaw, tilt, piece) in enumerate(((45.0, 14.0, mint), (135.0, -14.0, coral))):
        rot = rot_y(yaw) @ rot_x(tilt)
        _ring(rings, sc, ORBIT_R, 0.7, 0.45, rot, segments=40)
        node = rot @ Vector((ORBIT_R, 0.0, 0.0))  # equator crossing (y = 0)
        for s in (-1, 1):
            c = Vector(sc) + node * s
            ellipsoid(piece, tuple(c), (1.5, 1.5, 1.5), rings=7, segments=12)
            _ring(band, tuple(c), 2.2, 0.5, 0.12, rot_z(18.0 * s) @ rot_y(yaw), segments=16)
    return m


def build_beam_towers():
    """
    Beam Towers (SAME pivot as the star core): two chrome towers behind the sun (local (+-26, 0, 14))
    on violet plinths with mint rings, each topped by a glowing emitter orb in a chrome claw, sending
    a soft translucent beam (Glass) toward the sun cage (it stops 0.8 outside the cage, R24).
    """
    m = Model("M6_BeamTowers", f"SAME pivot as M6_StarCore; towers at local (+-{TOWER_X}, 0, {TOWER_Z}), {TOWER_H} tall", budget=3500)
    plinth = m.piece("Plinths", VIOLET)
    shaft = m.piece("Shafts", CHROME)
    rings = m.piece("Rings", MINT)
    claw = m.piece("Claws", CHROME_SHADE)
    orb = m.piece("Emitters", SUN_LIGHT, material="Smooth")
    beam = m.piece("Beams", (190, 255, 230), material="Glass", transparency=0.55)
    sc = Vector((0.0, SUN_Y, 0.0))
    for sx in (-1, 1):
        b = Vector((sx * TOWER_X, 0.0, TOWER_Z))
        revolve(plinth, [(0.0, 0.0), (3.4, 0.0), (3.4, 1.0), (2.6, 1.6), (0.0, 1.6)], center=tuple(b), segments=14)
        revolve(shaft, [(0.0, 1.5), (2.0, 1.5), (1.6, TOWER_H - 6), (1.2, TOWER_H - 2), (0.0, TOWER_H - 2)], center=tuple(b), segments=14)
        for y in (7.0, 15.0, 23.0):
            rr = 2.0 - 0.4 * (y - 1.5) / (TOWER_H - 7.5)
            revolve(rings, [(rr - 0.1, y), (rr + 0.25, y), (rr + 0.25, y + 0.8), (rr - 0.1, y + 0.8)], center=tuple(b), segments=14, closed=True)
        top = b + Vector((0, TOWER_H, 0))
        for k in range(4):
            a = math.radians(45 + 90 * k)
            p = Vector((math.cos(a) * 1.6, 0, math.sin(a) * 1.6))
            bar(claw, tuple(b + Vector((0, TOWER_H - 2.2, 0)) + p * 0.6), tuple(top + p + Vector((0, 0.6, 0))), 0.35)
        ellipsoid(orb, tuple(top), (1.5, 1.5, 1.5), rings=7, segments=12)
        d = (sc - top).normalized()
        end = sc - d * (CAGE_R + 0.8)
        cylinder(beam, tuple(top + d * 1.3), tuple(end), 0.6, segments=10, radius_b=0.85)
    return m


def build_plasma_pipes():
    """
    Plasma Pipes (front centre between the tanks, slot (0, 0.5, 23)): two glowing violet plasma pipes
    on chrome clamps running from the pedestal's front ports out to two round glass plasma tanks
    with swirling pink plasma and bobbing Bubbles (the pipes end 0.15 short of the ports).
    """
    port_z = CORE_SLOT[1] - math.sqrt(TIER1_R**2 - 6.0**2) - 0.4 - 0.8 - 0.15 - PIPES_SLOT_Z
    m = Model("M6_PlasmaPipes", f"front centre (layout: slot (0, 0.5, {PIPES_SLOT_Z})); tanks at x +-{TANK_X}; pipes end at local z {port_z:.2f}", budget=3000)
    pipe = m.piece("PlasmaPipes", LAVENDER, material="Smooth")
    clamp = m.piece("Clamps", CHROME_SHADE)
    base = m.piece("TankBases", VIOLET)
    glass = m.piece("TankGlass", GLASS_TINT, material="Glass", transparency=0.45)
    plasma = m.piece("Plasma", NEBULA_PINK, material="Smooth")
    bubbles = m.piece("Bubbles", PINK, material="Smooth")
    caps = m.piece("TankCaps", CHROME)
    for sx in (-1, 1):
        x0, x1 = sx * TANK_X, sx * 6.0
        path = [(x0, 2.2, 1.8), (x0, 1.1, 3.0), ((x0 + x1) / 2, 1.1, 5.0), (x1, 1.1, 7.0), (x1, 1.1, port_z - 0.6), (x1, 1.5, port_z)]
        tube(pipe, path, 0.55, sides=8)
        for z in (4.2, 7.5, port_z - 2.0):
            if z < port_z - 0.8:
                x = x0 + (x1 - x0) * min(max((z - 3.0) / 4.0, 0.0), 1.0)
                block(clamp, (x, 0.55, z), (1.6, 1.1, 0.5), bevel=0.15)
        # Tank: violet base, glass cylinder, pink plasma swirl column + bubbles, chrome cap.
        revolve(base, [(0.0, 0.0), (2.2, 0.0), (2.2, 0.8), (1.9, 1.0), (0.0, 1.0)], center=(x0, 0, 0), segments=14)
        cylinder(glass, (x0, 0.95, 0), (x0, 4.6, 0), 1.7, segments=14)
        cylinder(plasma, (x0, 1.0, 0), (x0, 3.2, 0), 1.35, segments=12)
        for k in range(3):
            a = math.radians(40 + 120 * k)
            ellipsoid(bubbles, (x0 + 0.7 * math.cos(a), 3.6 + 0.3 * k, 0.7 * math.sin(a)), (0.3, 0.3, 0.3), rings=3, segments=6)
        revolve(caps, [(0.0, 4.55), (1.95, 4.55), (1.95, 5.0), (1.2, 5.5), (0.0, 5.6)], center=(x0, 0, 0), segments=14)
    return m


WHEEL_R = 1.9


def build_coolant_pump():
    """
    Coolant Pump (placed twice): a chrome base with a big mint coolant tank (a glass window with
    bobbing Bubbles), sunny pipes and a side flywheel (WheelFly* spin about X: rim, spokes and hub are
    all centred on the axle), plus a little coral gauge.
    """
    m = Model("M6_CoolantPumps", "ground centre; flywheel axle along X on the +X side; WheelFly* spin X", budget=2500)
    base = m.piece("Base", CHROME_SHADE)
    tank = m.piece("Tank", MINT)
    window = m.piece("Window", GLASS_TINT, material="Glass", transparency=0.4)
    bubbles = m.piece("Bubbles", SKY, material="Smooth")
    pipes = m.piece("Pipes", SUNNY)
    wheel = m.piece("WheelFlyRim", CORAL)
    hub = m.piece("WheelFlyHub", CHROME)
    gauge = m.piece("Gauge", CORAL)
    block(base, (0, 0.4, 0), (5.2, 0.8, 4.2), bevel=0.2)
    cylinder(tank, (-0.6, 0.75, 0), (-0.6, 5.2, 0), 1.7, segments=14)
    revolve(tank, [(0.0, 5.15), (1.7, 5.15), (1.2, 5.9), (0.0, 6.1)], center=(-0.6, 0, 0), segments=14)
    oriented_ellipsoid(window, (-0.6, 3.0, -1.72), (0.9, 1.4, 0.12), normal=(0, 0, -1), rings=4, segments=10)
    for k in range(3):
        ellipsoid(bubbles, (-0.6 + 0.35 * (k - 1), 2.4 + 0.6 * k, -1.62), (0.22, 0.22, 0.1), rings=3, segments=6)
    tube(pipes, [(-0.6, 5.9, 0), (-0.6, 6.6, 0), (1.4, 6.6, 0), (1.4, 3.6, 0)], 0.35, sides=8)
    ax = Vector((2.6, 3.0, 0.0))
    block(base, (1.6, 1.9, 0), (1.0, 2.6, 1.0), bevel=0.2)
    revolve(wheel, [(WHEEL_R - 0.35, -0.25), (WHEEL_R, -0.25), (WHEEL_R, 0.25), (WHEEL_R - 0.35, 0.25)], center=tuple(ax), segments=16, closed=True, rot=rot_z(90))
    for k in range(3):
        r = rot_x(60.0 * k)
        d = r @ Vector((0, WHEEL_R - 0.3, 0))
        bar(wheel, tuple(ax - d), tuple(ax + d), 0.22)
    cylinder(hub, tuple(ax - Vector((0.9, 0, 0))), tuple(ax + Vector((0.4, 0, 0))), 0.45, segments=10)
    oriented_ellipsoid(gauge, (0.9, 2.2, -2.15), (0.45, 0.45, 0.08), normal=(0, 0, -1), rings=3, segments=10)
    return m


def build_nebula_core():
    """
    Nebula Core: a violet base under a glass dome holding a softly pulsing pink nebula orb (Core
    light) wrapped in three tilted swirl rings (pink / violet / mint, Twirl*: each point-symmetric
    about the dome axis, so they spin together without wobble), with chrome legs and a star on top.
    """
    m = Model("M6_NebulaCore", "ground centre of the dome; Core = nebula orb light; Twirl* spin Y", budget=3000)
    base = m.piece("Base", VIOLET)
    legs = m.piece("Legs", CHROME_SHADE)
    dome = m.piece("Dome", GLASS_TINT, material="Glass", transparency=0.55)
    orb = m.piece("CoreOrb", NEBULA_PINK, material="Smooth")
    s1 = m.piece("TwirlPink", PINK)
    s2 = m.piece("TwirlViolet", LAVENDER)
    s3 = m.piece("TwirlMint", MINT)
    top = m.piece("TopStar", SUNNY)
    revolve(base, [(0.0, 0.0), (5.6, 0.0), (5.6, 1.0), (5.0, 1.6), (0.0, 1.6)], segments=20)
    for k in range(6):
        a = math.radians(30 + 60 * k)
        bar(legs, (math.cos(a) * 5.2, 0.0, math.sin(a) * 5.2), (math.cos(a) * 4.7, 1.8, math.sin(a) * 4.7), 0.45)
    revolve(dome, [(0.0, 9.8), (2.4, 9.4), (3.9, 8.0), (4.7, 5.6), (4.85, 1.6), (0.0, 1.6)], segments=20)
    c = (0.0, 5.4, 0.0)
    ellipsoid(orb, c, (1.6, 1.6, 1.6), rings=8, segments=12)
    for piece, tilt, yaw, rr in ((s1, 30.0, 0.0, 2.8), (s2, -35.0, 60.0, 3.3), (s3, 60.0, 120.0, 2.4)):
        _ring(piece, c, rr, 0.35, 0.3, rot_y(yaw) @ rot_x(tilt), segments=24)
        for s in (-1, 1):
            p = Vector(c) + (rot_y(yaw) @ rot_x(tilt) @ Vector((rr, 0, 0))) * s
            ellipsoid(piece, tuple(p), (0.35, 0.35, 0.35), rings=3, segments=6)
    star_plate(top, (0.0, 10.9, 0.0), 1.0, thickness=0.4)
    return m


def build_meteor_falls():
    """
    Meteor Falls: a stepped moon-rock cliff (crystals and glowing meteor rocks set in it) with a
    sparkly "star water" stream across its top pouring over the lip and down the front (StarFall*:
    W8's WorldFx scroll row) into a chrome-rimmed pool with bobbing Bubbles and a SteamA sparkle puff.
    """
    m = Model("M6_MeteorFalls", "ground centre of the pool (front); cliff toward +Z (z 3..12.6, 19 tall); StarFall* + SteamA", budget=3500)
    cliff = m.piece("Cliff", MOON_ROCK)
    cliff2 = m.piece("CliffDark", MOON_DARK)
    meteor = m.piece("Meteors", (120, 104, 140))
    glow = m.piece("MeteorGlow", SUN_LIGHT, material="Smooth")
    cry_a = m.piece("CrystalsMint", MINT)
    cry_b = m.piece("CrystalsViolet", LAVENDER)
    rim = m.piece("PoolRim", CHROME_SHADE)
    water = m.piece("StarFall", STAR_WATER, material="Smooth")
    bubbles = m.piece("Bubbles", SKY, material="Smooth")
    steam = m.piece("SteamA", (244, 244, 255), material="Smooth")
    for k, (y0, h, w, z0, d) in enumerate(((0.0, 7.0, 15.0, 3.0, 9.6), (6.8, 6.6, 13.4, 3.6, 8.6), (13.2, 5.6, 11.6, 4.0, 7.8))):
        block(cliff if k % 2 == 0 else cliff2, (0, y0 + h / 2, z0 + d / 2), (w, h, d), bevel=0.9)
    for k, (x, y, z, s) in enumerate(((-6.6, 4.0, 3.4, 1.0), (5.6, 9.5, 4.0, 0.9), (-4.6, 15.0, 4.3, 0.8))):
        moon_rock(meteor, (x, y, z), (s, s, s), seed=k * 7 + 3)
        oriented_ellipsoid(glow, (x, y, z - s * 0.8), (s * 0.5, s * 0.5, 0.2), normal=(0, 0, -1), rings=4, segments=8)
    for k, (x, y, z) in enumerate(((5.5, 18.8, 6.0), (-4.0, 18.8, 9.0), (6.4, 6.8, 3.8))):
        crystal(cry_a if k % 2 == 0 else cry_b, (x, y, z), 2.6, 0.5)
        crystal(cry_b if k % 2 == 0 else cry_a, (x + 0.7, y, z + 0.5), 1.6, 0.35, tilt_x=20, tilt_z=-20)
    # Star water: a stream on the top, over the lip, down the stepped front, into the pool.
    from models.dino_area05 import ribbon

    block(water, (0.8, 18.92, 6.6), (2.4, 0.2, 6.6), bevel=0.0)
    path = [(0.8, 19.02, 3.6), (0.8, 18.8, 2.95), (0.8, 16.6, 2.2), (0.8, 13.6, 2.25), (0.8, 12.6, 2.85), (0.8, 10.0, 1.95), (0.8, 6.8, 1.55), (0.8, 3.4, 1.3), (0.8, 0.95, 0.9)]
    normals = [(0, 1, -0.25), (0, 0.6, -1), (0, 0.05, -1), (0, 0.05, -1), (0, 0.5, -1), (0, 0.05, -1), (0, 0.05, -1), (0, 0.05, -1), (0, 0.4, -1)]
    ribbon(water, path, normals, [2.4, 2.4, 2.2, 2.2, 2.3, 2.4, 2.6, 2.8, 3.0], thick=0.3)
    revolve(rim, [(3.0, 0.0), (4.2, 0.0), (4.2, 1.2), (3.9, 1.4), (3.1, 1.4), (3.0, 1.1)], center=(0.8, 0, 0.6), segments=18, closed=True)
    disc(water, (0.8, 0, 0.6), 3.1, 0.95, segments=18, bevel=0.0)
    for k in range(4):
        a = math.radians(60 + 90 * k)
        ellipsoid(bubbles, (0.8 + 1.8 * math.cos(a), 1.0, 0.6 + 1.5 * math.sin(a)), (0.35, 0.24, 0.35), rings=3, segments=6)
    for dx, dy, dz, r in ((0.2, 2.3, 0.0, 0.9), (1.2, 2.9, -0.4, 0.7), (-0.4, 3.5, -0.2, 0.55)):
        ellipsoid(steam, (0.8 + dx, dy, 0.6 + dz), (r, r * 0.85, r), rings=4, segments=7)
    return m


SPIRE_H = DECK_Y - 0.5  # platform top (SPIRE_H + 0.5) = the deck height
TILE_T = 0.3


def _bridge_points():
    """
    Star bridge geometry in SPIRE-LOCAL coordinates: (start on the spire platform edge, end on the
    pedestal deck 1.5 inside its edge) at tile-centre height (tiles rest on the deck top).
    """
    a = math.radians(BRIDGE_A)
    r_end = DECK_R - 1.5
    end_slot = Vector((CORE_SLOT[0] + r_end * math.cos(a), DECK_Y + TILE_T / 2 + 0.1, CORE_SLOT[1] + r_end * math.sin(a)))
    end = end_slot - Vector((SPIRE_SLOT[0], 0.0, SPIRE_SLOT[1]))
    flat = Vector((end.x, 0, end.z)).normalized()
    start = flat * 2.4 + Vector((0, SPIRE_H + 0.5 + TILE_T / 2 + 0.1, 0))
    return start, end, flat


def build_star_bridge():
    """
    Star Bridge: a lumpy moon-rock spire with a chrome platform, a crystal cluster and a lamp, and a
    gently arched bridge of floating star tiles (alternating sunny / lavender, on two thin chrome
    rails) to the star-core deck (it rests on the deck top inside the railing gap). Lamp = light.
    """
    start, end, flat = _bridge_points()
    m = Model(
        "M6_StarBridge",
        f"spire foot (layout: slot ({SPIRE_SLOT[0]}, 0.5, {SPIRE_SLOT[1]})); tiles {tuple(round(c, 2) for c in start)} -> "
        f"{tuple(round(c, 2) for c in end)} (spire-local; deck top at the end)",
        budget=3500,
    )
    rock = m.piece("Spire", MOON_ROCK)
    platform = m.piece("Platform", CHROME)
    rails = m.piece("Rails", CHROME_SHADE)
    tiles_a = m.piece("TilesSunny", SUNNY)
    tiles_b = m.piece("TilesLavender", LAVENDER)
    cry_a = m.piece("CrystalsMint", MINT)
    cry_b = m.piece("CrystalsViolet", VIOLET)
    lamp = m.piece("Lamp", SUN_LIGHT, material="Neon")
    secs = []
    for k, (y, r) in enumerate(((0.0, 3.6), (2.5, 3.3), (5.0, 3.0), (7.0, 2.8), (SPIRE_H, 2.7))):
        ring = []
        for i in range(10):
            a = 2 * math.pi * i / 10
            rr = r * (1 + 0.08 * math.sin(3 * a + k) + 0.05 * math.sin(5 * a + 2 * k))
            ring.append((rr * math.cos(a), y, rr * math.sin(a)))
        secs.append(ring)
    loft(rock, secs, cap_start=True, cap_end=True)
    disc(platform, (0, SPIRE_H, 0), 3.3, 0.5, segments=14, bevel=0.1)
    back = -flat
    crystal(cry_a, tuple(back * 1.6 + Vector((0.6, SPIRE_H + 0.45, 0.0))), 2.4, 0.5)
    crystal(cry_b, tuple(back * 1.6 + Vector((-0.5, SPIRE_H + 0.45, 0.6))), 1.6, 0.35, tilt_x=15, tilt_z=20)
    side = Vector((-flat.z, 0, flat.x))
    lp = side * 2.3 + Vector((0, SPIRE_H + 0.5, 0))
    cylinder(rails, tuple(lp), tuple(lp + Vector((0, 3.0, 0))), 0.16, segments=6)
    ellipsoid(lamp, tuple(lp + Vector((0, 3.3, 0))), (0.42, 0.42, 0.42), rings=4, segments=6)
    # Bridge: a gentle upward arch (rise 1.2) of star tiles on two rails.
    length = (end - start).length
    count = int(length / 2.4)  # star footprint ~2.1 along the path: neighbours never overlap (R18)
    rise = 1.2

    def at(t):
        p = start.lerp(end, t)
        p.y += rise * 4 * t * (1 - t)
        return p

    for s in (-1, 1):
        off = side * (s * 1.1)
        for i in range(10):
            p0, p1 = at(i / 10) + off - Vector((0, 0.3, 0)), at((i + 1) / 10) + off - Vector((0, 0.3, 0))
            bar(rails, tuple(p0), tuple(p1), 0.14)
    for i in range(count):
        t = (i + 0.5) / count
        # Every other tile 0.08 higher: neighbouring stars overlap a little, and near the arch's
        # peak two of them would otherwise share one top plane (owner R18).
        p = at(t) + Vector((0, 0.08 if i % 2 else 0.0, 0))
        normal = Vector((0, 1, 0))
        up = flat
        star_plate(tiles_a if i % 2 == 0 else tiles_b, tuple(p), 1.15, thickness=TILE_T, normal=tuple(normal), up=tuple(up))
    return m


def build_galaxy_crown():
    """
    Galaxy Crown (SAME pivot as the star core): a gold band ring hugging the statue platform's rim
    (above the cage's top pole, so it never cuts a cage ring) with eight star points on short stalks fanning outward (sunny / lavender alternating),
    violet gems between them and a soft sparkle at each tip (Crystal: light).
    """
    m = Model("M6_GalaxyCrown", f"SAME pivot as M6_StarCore; band at y {TOP_Y - 0.7:.1f}..{TOP_Y + 0.1:.1f} round the platform rim", budget=3000)
    band = m.piece("Band", GOLD)
    stalks = m.piece("Stalks", GOLD_DARK)
    sa = m.piece("StarsSunny", SUNNY)
    sb = m.piece("StarsLavender", LAVENDER)
    gems = m.piece("Gems", VIOLET, material="Smooth")
    tips = m.piece("CrystalTips", (255, 240, 180), material="Neon")
    yb = TOP_Y - 0.3
    _ring(band, (0.0, yb, 0.0), 4.1, 0.8, 0.8, None, segments=24)
    for k in range(8):
        a = math.radians(22.5 + 45 * k)
        out = Vector((math.cos(a), 0, math.sin(a)))
        b = Vector((0.0, yb, 0.0)) + out * 4.4
        tip = b + out * 2.6 + Vector((0, 3.0, 0))
        bar(stalks, tuple(b), tuple(tip), 0.35)
        star_plate(sa if k % 2 == 0 else sb, tuple(tip + Vector((0, 0.9, 0))), 1.1, thickness=0.45, normal=tuple(out), up=(0, 1, 0))
        ellipsoid(tips, tuple(tip + Vector((0, 2.2, 0)) + out * 0.1), (0.22, 0.22, 0.22), rings=3, segments=5)
        ag = a + math.pi / 8
        oriented_ellipsoid(gems, (math.cos(ag) * 4.55, yb, math.sin(ag) * 4.55), (0.4, 0.3, 0.15), normal=(math.cos(ag), 0, math.sin(ag)), rings=4, segments=8)
    return m


LUX_SKIN = (124, 204, 255)  # Commander Lux: friendly sky-blue alien astronaut


def _astronaut(parts, a, helmet, collar, pack, badge):
    """
    Astronaut kit on a toon_biped: a clear helmet bubble round the head (Glass), a chrome collar ring,
    a coral backpack with two little tanks, and a sunny star badge on the chest.
    """
    hc, hr = a["head"], a["head_r"]
    r = max(hr) + 0.32
    ellipsoid(helmet, hc, (r, r * 0.98, r), rings=8, segments=14)
    bc, br = a["body_c"], a["body"]
    neck_y = a["neck"]
    revolve(collar, [(0.65, neck_y - 0.2), (1.15, neck_y - 0.2), (1.15, neck_y + 0.25), (0.65, neck_y + 0.25)], center=(0.0, 0.0, hc[2]), segments=14, closed=True)
    block(pack, (0.0, bc[1] + 0.2, bc[2] + br[2] + 0.35), (1.8, 2.0, 0.8), bevel=0.3)
    for sx in (-1, 1):
        cylinder(pack, (sx * 0.5, bc[1] - 0.6, bc[2] + br[2] + 0.85), (sx * 0.5, bc[1] + 1.0, bc[2] + br[2] + 0.85), 0.32, segments=8)
    cx, cy, cz = a["chest"]
    star_plate(badge, (cx + 0.55, cy + 0.15, cz - 0.08), 0.32, thickness=0.12)


def build_commander_lux():
    """
    Commander Lux (Manager): a friendly sky-blue alien astronaut chief on W6's shared Moon body
    (toon_biped) in a white space suit with a clear bubble helmet, chrome collar, coral backpack and a
    sunny star badge, holding a clipboard in both hands, beside a mission console (screen + buttons).
    Figure at the model origin, yaw 0. R30 rig: the clipboard rides ArmR; ArmL is the wave arm;
    helmet / face ride the Head; suit, backpack and badge the Torso.
    """
    from models._critter_kit import eyes
    from models._npc_rig import rig_split

    m = Model("M6_CommanderLux", "ground centre between the feet; Lux faces -Z; mission console at local +X", budget=3000)
    skin = m.piece("Skin", LUX_SKIN, material="Smooth")
    suit = m.piece("Suit", CHROME)
    limbs = m.piece("SuitLimbs", CHROME)
    gloves = m.piece("Gloves", CORAL)
    boots = m.piece("Boots", NAVY, material="Smooth")
    face = m.piece("Face", EYE, material="Smooth")
    shine = m.piece("Shine", SHINE, material="Smooth")
    helmet = m.piece("Helmet", GLASS_TINT, material="Glass", transparency=0.6)
    collar = m.piece("Collar", CHROME_SHADE)
    pack = m.piece("Backpack", CORAL)
    badge = m.piece("Badge", SUNNY, material="Smooth")
    board = m.piece("Clipboard", NAVY)
    paper = m.piece("ClipPaper", (250, 250, 255), material="Smooth")
    console = m.piece("Console", VIOLET)
    screen = m.piece("Screen", MINT, material="Smooth")
    buttons = m.piece("Buttons", SUNNY, material="StudsSmall")
    a = toon_biped(
        {"body": suit, "head": skin, "limbs": limbs, "hands": gloves, "feet": boots},
        body=(1.35, 1.3, 1.2),
        head=(1.05, 0.98, 1.0),
        leg_h=1.3,
        arm_pose={"left": (-18.0, 72.0), "right": (-18.0, 72.0)},
    )
    hc, hr = a["head"], a["head_r"]
    eyes(face, shine, hc, hr, yaw=24.0, pitch=8.0, size=0.24, tall=1.25)
    smile(face, hc, hr, pitch=-22.0, width=24.0, depth=9.0, thickness=0.06, steps=6)
    _astronaut(None, a, helmet, collar, pack, badge)
    (lx, ly, lz), (rx, ry, rz) = a["hands"]["left"], a["hands"]["right"]
    clipboard_helper(board, paper, ((lx + rx) / 2, (ly + ry) / 2 + 0.3, min(lz, rz) - 0.3), tilt=-22.0)
    # Mission console at local +X: a violet pedestal with a slanted top, a mint screen and buttons.
    px = 4.1
    block(console, (px, 1.3, 0.2), (2.4, 2.6, 1.8), bevel=0.3)
    block(console, (px, 2.75, 0.1), (2.6, 0.3, 2.0), bevel=0.08, rot=rot_x(-18))
    block(screen, (px - 0.35, 2.95, 0.05), (1.2, 0.08, 0.9), bevel=0.0, rot=rot_x(-18))
    for k in range(3):
        ellipsoid(buttons, (px + 0.65, 2.9 + 0.12 * k, -0.35 + 0.35 * k), (0.16, 0.1, 0.16), rings=3, segments=6)
    rig_split(
        m,
        toon_bones(a),
        static=("Console", "Screen", "Buttons"),
        assign={
            "Suit": "Torso", "Backpack": "Torso", "Badge": "Torso", "Collar": "Torso", "Helmet": "Head", "Face": "Head",
            "Shine": "Head", "Clipboard": "ArmR", "ClipPaper": "ArmR",
        },
    )
    return m


STATUE_SCALE = 2.8


def build_golden_astronaut():
    """
    FINALE — the Golden Astronaut Statue on the star core's top platform: W6's shared Moon body at
    2.8x, all gold (light-gold helmet bubble and backpack, dark-gold boots), waving with the left arm
    and planting a golden star flag with the right. Glow-budget safe: gold studs + Smooth gems only.
    """
    m = Model(
        "M6_GoldenAstronaut",
        f"top platform centre of the star core (layout: CORE * (0, {TOP_Y}, 0)); faces -Z; {STATUE_SCALE}x Moon body",
        budget=6000,
    )
    gold = m.piece("Gold", GOLD)
    light = m.piece("GoldLight", GOLD_LIGHT)
    dark = m.piece("GoldDark", GOLD_DARK)
    eyes_p = m.piece("Eyes", EYE, material="Smooth")
    flag = m.piece("Flag", GOLD_LIGHT)
    gem = m.piece("Gems", CORAL, material="Smooth")

    def statue():
        from models._critter_kit import eyes

        a = toon_biped(
            {"body": gold, "head": gold, "limbs": gold, "hands": light, "feet": dark},
            body=(1.35, 1.3, 1.2),
            head=(1.05, 0.98, 1.0),
            leg_h=1.3,
            arm_pose={"left": (60.0, 165.0), "right": (14.0, 70.0)},
        )
        hc, hr = a["head"], a["head_r"]
        eyes(eyes_p, None, hc, hr, yaw=24.0, pitch=8.0, size=0.24, tall=1.25)
        smile(eyes_p, hc, hr, pitch=-22.0, width=24.0, depth=9.0, thickness=0.06, steps=6)
        _astronaut(None, a, light, dark, light, gem)
        # Dark-gold visor on the helmet front (the statue's helmet is solid gold, not glass).
        from models._critter_kit import surface

        r = max(hr) + 0.32
        p, n = surface(hc, (r, r * 0.98, r), 0.0, 6.0)
        oriented_ellipsoid(dark, tuple(p - n * 0.08), (0.95, 0.7, 0.16), normal=tuple(n), rings=4, segments=10)
        # Star flag: pole from the right hand down to the platform + a star pennant on top.
        rx, ry, rz = a["hands"]["right"]
        cylinder(dark, (rx, 0.0, rz), (rx, ry + 3.2, rz), 0.12, segments=6)
        star_plate(flag, (rx + 0.75, ry + 2.6, rz), 0.7, thickness=0.16)
        return a

    place_new([gold, light, dark, eyes_p, flag, gem], statue, Xf((0.0, 0.0, 0.0)), STATUE_SCALE)
    return m


BUILDERS = {
    "M6_Floor": build_floor,
    "M6_EntryArch": build_entry_arch,
    "M6_StarCore": build_star_core,
    "M6_OrbitRings": build_orbit_rings,
    "M6_BeamTowers": build_beam_towers,
    "M6_PlasmaPipes": build_plasma_pipes,
    "M6_CoolantPumps": build_coolant_pump,
    "M6_NebulaCore": build_nebula_core,
    "M6_MeteorFalls": build_meteor_falls,
    "M6_StarBridge": build_star_bridge,
    "M6_GalaxyCrown": build_galaxy_crown,
    "M6_CommanderLux": build_commander_lux,
    "M6_GoldenAstronaut": build_golden_astronaut,
}
