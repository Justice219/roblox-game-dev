"""
moon_area04.py — Moon Base area M4 "Asteroid Mine" (spec 2026-10-31-r69-moon-lucky-juice-design §2.2,
owner R70; W7 art-d34): a crater field where a friendly drill rig bores candy crystals out of a
chunky asteroid, two ore carts loop round a track to a crystal sorter, little asteroids float on
tethers, horseshoe gravity magnets hold rocks in mid-air, two "drill beam" turrets sparkle at a
crystal rock, hover steps climb to a lookout and a giant Mega Asteroid floats at the back.
Every pad purchase is its own model set so each one builds in separately; placement lives in
src/shared/Config/Worlds/Moon/Layouts/Area04.luau.

Shared Moon palette + helpers: W6's models.moon_area01 (crater, moon_arch, moon_nuke, toon_biped /
toon_bones) and moon_area03.py (palette names, floor_rock, crystal, toon_face).

Every model has its OWN pivot (ground centre unless stated, front = -Z). The layout places it with
a slot-local CFrame (identity faces the road); floor-standing models sit at y = 0.4 (floor top).

Models (key: pivot / notes)                                         build key
    M4_Floor          slab centre at ground; top y = 0.4                base
    M4_EntryArch      ground centre of the walkway opening; stacked     base
                      moon-rock pillars, crystal crowns, double-sided
                      "ASTEROID / MINE" letters (R17)
    M4_Rocks          slot origin on the floor top; back rocks +        base
                      crystals (centre clear for the Mega Asteroid)
    M4_DrillRig       PRODUCER "Asteroid Drill": platform, cradled      M4_DrillRig
                      asteroid, gantry with a spinning drill bit (Rotor),
                      crystal chute toward +X, console with floating Nukes
    M4_TetherRock     floating asteroid on a cable (Float assembly)     M4_TetherCables (x3)
    M4_CartTrack      oval rail loop; pivot = loop centre               M4_OreCarts
    M4_OreCart        ROUTED cart (R56): WheelsF / WheelsR + HubsF /     M4_OreCarts (x2)
                      HubsR per axle, cargo Ore + OreCyan; pivot = rail top
    M4_CrystalSorter  hopper + machine + Belt + candy crystal bins      M4_CrystalSorter
    M4_GravityMagnet  horseshoe magnet on a post with a floating rock   M4_GravityMagnets (x2)
    M4_LaserDrills    two friendly drill-beam turrets + a crystal rock  M4_LaserDrills
    M4_MegaAsteroid   HERO: giant floating crystal asteroid on 4 cables M4_MegaAsteroid
    M4_Drillbert      Manager NPC figure ONLY (R30 rig groups)          M4_Drillbert
    M4_HoverStep      one floating step (whole model hovers)            M4_HoverSteps (x5)
    M4_HoverDeck      floating lookout deck with railing + telescope    M4_HoverSteps

Animation contract (rows in WorldFxConfig "Moon Base M3/M4" block; route in VehicleRouteConfig):
    Rotor             M4_DrillRig drill bit (existing Rotor spin row; the bit is rotationally
                      symmetric about its vertical axis).
    Belt              M4_CrystalSorter conveyor (existing Belt scroll row).
    Nuke*             M4_DrillRig floating candy nukes (existing Nuke bob row, 0.4 above the console).
    Float (Assembly)  M4_TetherRock / M4_GravityMagnet rocks; FloatBig for M4_MegaAsteroid. Every
                      cable / magnet stays still and reaches >= 1 stud into its rock, so the bob
                      never shows a gap (R25).
    Hover (Assembly)  M4_HoverStep / M4_HoverDeck: the whole model bobs gently.
    Ore cart route    M4_OreCart: wheel pieces per axle (bbox centre on the axle), cargo groups
                      { Ore, OreCyan }, tip toward local +X (the sorter) about hinge (1.35, 0.95, 0).
    Static on purpose: Beams (translucent drill beams, Smooth), Sparkles, Core* (small Neon).

Budgets: floor <= 2,500, arch <= 4,500, backdrop <= 4,500, producer <= 6,000, hero <= 6,000, props
<= 2,500, cart <= 1,500, manager <= 3,000. A fully built M4 stays <= 28k triangles.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import Model
from snkit.kit import block, disc
from snkit.shapes import bar, box, cylinder, ellipsoid, frame_from, loft, revolve, ring_tube, rot_x, rot_y

from models._critter_kit import oriented_ellipsoid, star, tube
from models.area04 import _hash
from models.dino_area03 import FLOOR_TOP, SLOT_D, SLOT_W, _chute_section
from models.moon_area01 import crater, moon_arch, moon_nuke, toon_biped, toon_bones  # W6's shared Moon helpers
from models.moon_area03 import (
    BEAM,
    CHROME,
    CHROME_SHADE,
    CORAL,
    CRATER,
    CRATER_RIM,
    CRYSTAL_CYAN,
    CRYSTAL_PINK,
    GLASS,
    MINT,
    MOON_GROUND,
    MOON_GROUND_DARK,
    MOON_ROCK,
    MOON_ROCK_DARK,
    NAVY,
    NEON_MINT,
    PATH,
    SUNNY,
    VIOLET,
    VIOLET_DARK,
    crystal,
    floor_rock,
)

ASTEROID = (166, 150, 176)  # warm violet-grey asteroid rock
ASTEROID_DARK = (132, 118, 146)


def asteroid(piece, center, radii, seed: int = 0, rings: int = 6, segments: int = 10, lump: float = 0.22):
    """
    Chunky floating asteroid: an ellipsoid with a deterministic lumpy deform (bigger lumps than
    moon_rock, no floor clamp: it floats). ~2 * segments * (rings - 1) triangles.

    Example: asteroid(rock, (0, 20, 0), (6, 5, 5.5), seed=7, rings=7, segments=12)
    """

    def lumpy(x, y, z):
        k = 1.0 + lump * (_hash(seed + x * 1.7, z * 1.3 + y * 0.9) - 0.5)
        return (x * k, y * k, z * k)

    ellipsoid(piece, center, radii, rings=rings, segments=segments, deform=lumpy)


def gem_cluster(pink, cyan, center, scale: float = 1.0, seed: int = 0, count: int = 4, up=(0.0, 1.0, 0.0)):
    """A few pink / cyan crystals fanning out of `center` around the direction `up` (tilts in deg)."""
    cx, cy, cz = center
    ux, uy, uz = up
    base_tx = math.degrees(math.atan2(-uz, uy)) if abs(uy) > 1e-6 or abs(uz) > 1e-6 else 0.0
    base_tz = -math.degrees(math.atan2(ux, max(1e-6, math.hypot(uy, uz))))
    for k in range(count):
        a = 2 * math.pi * k / count + seed
        piece = pink if (k + seed) % 2 == 0 else cyan
        h = scale * (1.3 + 1.2 * _hash(seed, k))
        crystal(piece, (cx, cy, cz), h, 0.32 * scale, tilt_x=base_tx - 22 * math.cos(a), tilt_z=base_tz + 22 * math.sin(a))


# ------------------------------------------------------------------------------------------------
# Base: floor, entry arch, rocks
# ------------------------------------------------------------------------------------------------

# Floor craters (floor-local: slot z - 35): off the walkway, the cart loop, the pad strip.
M4_CRATERS = ((-34, -16, 4.0), (26, -16, 3.0), (-44, 4, 3.0), (-14, 4, 2.4), (-30, 8, 2.6), (36, 24, 2.2))


def build_floor():
    """Moon-dust slab for the whole slot, dust patches, raised-rim craters and a chrome-white tile
    walkway from the road to the drill console (no flat top shares a plane, R18)."""
    m = Model("M4_Floor", "slab centre at ground (place at slot (0, 0, 35)); top y = 0.4", budget=2500)
    ground = m.piece("Ground", MOON_GROUND)
    patch = m.piece("Dust", MOON_GROUND_DARK)
    rims = m.piece("CraterRims", CRATER_RIM)
    bowls = m.piece("CraterBowls", CRATER)
    tiles = m.piece("Tiles", PATH)
    block(ground, (0, FLOOR_TOP / 2, 0), (SLOT_W, FLOOR_TOP, SLOT_D - 0.4), bevel=0.15)
    for i, (x, z, sx, sz) in enumerate(((-40, -26, 9, 6), (34, -28, 8, 6), (-46, 18, 6, 8), (12, -14, 6, 5), (-20, -4, 7, 5))):
        # Dust patches top out 0.07 above the floor: never the crater bowls' plane (+0.1, R18).
        block(patch, (x, FLOOR_TOP + 0.01, z), (sx, 0.12, sz), bevel=0.04, rot=rot_y(24 * (_hash(i, 40) - 0.5)))
    for x, z, r in M4_CRATERS:
        crater(rims, bowls, (x, FLOOR_TOP, z), r * 0.8, segments=10)
    z = -34.6
    k = 0
    while z < 3.6:
        length = min(3.6 + 1.0 * _hash(k, 41), 4.0 - z)
        if length < 0.8:
            break
        for s in (-1, 1):
            block(tiles, (s * 2.55, FLOOR_TOP + 0.08, z + length / 2), (4.5, 0.2, length - 0.4), bevel=0.1)
        z += length
        k += 1
    return m


def build_entry_arch():
    """W6's shared capsule-post Moon arch (moon_arch: double-sided letters R17, ringed-planet
    finials, crescent crest, small Neon star bulbs) dressed for the mine: "ASTEROID / MINE" in
    sunny letters on violet, lilac asteroid finials with sunny rings."""
    return moon_arch("M4_EntryArch", ["ASTEROID", "MINE"], board=VIOLET, planet=MOON_ROCK, ring=SUNNY, band_a=MINT, band_b=CORAL)


def build_rocks():
    """Back-corner moon rocks and crystal clusters (slot space, pivot = slot origin on the floor top).
    The back centre (|x| < 12) stays clear for the Mega Asteroid's anchors; near-road side rocks
    live in RocksL / RocksR (R31)."""
    m = Model("M4_Rocks", "slot origin on the floor top (place at slot (0, 0.4, 0)); slot-space coordinates", budget=4500)
    rocks = m.piece("Rocks", MOON_ROCK)
    dark = m.piece("RocksDark", MOON_ROCK_DARK)
    pink = m.piece("GemPink", CRYSTAL_PINK)
    cyan = m.piece("GemCyan", CRYSTAL_CYAN)
    rocks_l = m.piece("RocksL", MOON_ROCK)
    rocks_r = m.piece("RocksR", MOON_ROCK)
    for i, (x, z, rx, ry, rz) in enumerate(((-42, 66, 5.0, 4.0, 3.6), (-24, 67, 3.6, 2.8, 2.8), (22, 67, 3.6, 2.8, 2.8), (40, 66, 5.0, 4.2, 3.6))):
        floor_rock(rocks, (x, ry * 0.45, z), (rx, ry, rz), seed=320 + i, floor=0.0)
        floor_rock(dark, (x + (2.2 if x < 0 else -2.2), ry * 0.3, z - 2.0), (rx * 0.5, ry * 0.5, rz * 0.5), seed=330 + i, floor=0.0)
        gem_cluster(pink, cyan, (x - 0.4, ry * 1.25, z + 0.3), scale=1.2, seed=340 + i, count=4)
    for i, (x, z) in enumerate(((-15, 63), (15, 63.5), (47, 54), (-48, 50))):
        gem_cluster(pink, cyan, (x, 0.3, z), scale=1.0, seed=350 + i, count=3)  # roots start at the floor (R24)
    for i, z in enumerate((20.0, 30.0)):
        floor_rock(rocks_l, (48.0, 0.7, z), (2.0, 1.4, 1.8), seed=360 + i, floor=0.0)
    floor_rock(rocks_r, (-48.5, 0.7, 47.0), (1.9, 1.3, 1.7), seed=370, floor=0.0)
    return m


# ------------------------------------------------------------------------------------------------
# M4_DrillRig — producer "Asteroid Drill"
# ------------------------------------------------------------------------------------------------

ROCK_C = (0.0, 4.5, 1.2)  # cradled asteroid centre (local)
CONSOLE_Z = -8.0
CONSOLE_TOP = 2.6
CHUTE_END_X = 13.0  # the crystal chute ends over the cart track (slot x 14 straight)


def build_drill_rig():
    """
    Producer "Asteroid Drill": a violet octagon platform, a chunky asteroid held in four chrome
    claws with candy crystals poking out, a chrome gantry with a sunny motor and a spinning drill
    bit (Rotor) boring into the rock top, a crystal chute to the cart track (+X), and a console at
    the front with buttons, a screen and two floating candy nukes.
    """
    m = Model("M4_DrillRig", "platform centre on the floor; console toward -Z (road), chute toward +X", budget=6000)
    deck = m.piece("Deck", VIOLET)
    deck_rim = m.piece("DeckRim", SUNNY, material="StudsSmall")
    rock = m.piece("Rock", ASTEROID)
    pink = m.piece("GemPink", CRYSTAL_PINK)
    cyan = m.piece("GemCyan", CRYSTAL_CYAN)
    chrome = m.piece("Chrome", CHROME)
    shade = m.piece("ChromeShade", CHROME_SHADE, material="StudsSmall")
    motor = m.piece("Motor", SUNNY)
    rotor = m.piece("Rotor", CORAL)
    console = m.piece("Console", CHROME)
    top = m.piece("ConsoleTop", MINT)
    buttons = m.piece("Buttons", CORAL, material="Smooth")
    screen = m.piece("Screen", NAVY, material="Smooth")
    blips = m.piece("Blips", NEON_MINT, material="Smooth")
    chute = m.piece("Chute", CHROME_SHADE)
    nuke_body_p = m.piece("NukeBody", MOON_ROCK, material="StudsSmall")
    nuke_fins = m.piece("NukeFins", SUNNY, material="StudsSmall")
    band_l = m.piece("NukeBandL", NEON_MINT, material="Neon")
    band_r = m.piece("NukeBandR", NEON_MINT, material="Neon")
    rx, ry, rz = ROCK_C
    disc(deck, (0, 0, rz), 6.5, 0.8, segments=8, bevel=0.2)
    ring_tube(deck_rim, (0, 0.62, rz), 6.15, 0.36, 0.3, segments=8)
    # Cradled asteroid + crystals (static: the producer's rock).
    asteroid(rock, ROCK_C, (3.0, 2.6, 2.8), seed=401, rings=6, segments=10, lump=0.18)
    for k, (ang, el) in enumerate(((40, 30), (160, 20), (260, 35), (320, -10))):
        a = math.radians(ang)
        e = math.radians(el)
        d = Vector((math.cos(a) * math.cos(e), math.sin(e), math.sin(a) * math.cos(e)))
        p = Vector(ROCK_C) + Vector((d.x * 2.5, d.y * 2.1, d.z * 2.3))
        gem_cluster(pink, cyan, tuple(p), scale=0.9, seed=410 + k, count=3, up=tuple(d))
    # Four chrome claws from the deck up round the rock.
    for k in range(4):
        a = math.radians(45 + 90 * k)
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        p0 = Vector((rx, 0.7, rz)) + d * 3.4
        p1 = Vector((rx, ry - 0.4, rz)) + d * 3.3
        p2 = Vector((rx, ry + 0.9, rz)) + d * 2.5
        tube(chrome, [tuple(p0), tuple(p1), tuple(p2)], 0.3, sides=6)
    # Gantry: two posts + crossbeam + motor + the drill bit (Rotor: cone + 3 spiral flights, all
    # rotationally symmetric about the vertical axis through (rx, rz)).
    for s in (-1, 1):
        cylinder(chrome, (s * 4.6, 0.7, rz), (s * 4.6, 11.4, rz), 0.42, segments=8)
    cylinder(chrome, (-5.1, 11.2, rz), (5.1, 11.2, rz), 0.5, segments=10)
    block(motor, (0, 10.2, rz), (2.0, 1.6, 2.0), bevel=0.25)
    cylinder(shade, (0, 9.3, rz), (0, 8.8, rz), 0.42, segments=8)
    bit_top, bit_tip = 8.9, ry + 1.5
    revolve(rotor, [(0.0, 0.0), (0.5, 0.0), (0.42, -(bit_top - bit_tip) * 0.6), (0.0, -(bit_top - bit_tip))], center=(rx, bit_top, rz), segments=8)
    for k in range(3):
        pts = []
        for j in range(7):
            t = j / 6
            a = 2 * math.pi * k / 3 + t * 2.2 * math.pi
            r = 0.58 - 0.38 * t
            pts.append((rx + r * math.cos(a), bit_top - 0.2 - t * (bit_top - bit_tip - 0.6), rz + r * math.sin(a)))
        tube(rotor, pts, 0.09, sides=4)
    # Crystal chute: from a hopper beside the rock down toward +X over the cart track.
    hop = Vector((4.3, 3.0, rz))
    block(chute, tuple(hop), (1.8, 1.0, 2.0), bevel=0.12)
    end = Vector((CHUTE_END_X, 3.6, rz))
    sec = []
    for p in (hop + Vector((0.8, 0.3, 0)), end):
        sec.append(_chute_section(p, Vector((0, 0, 1)), Vector((0, 1, 0))))
    loft(chute, sec)
    cylinder(shade, (CHUTE_END_X - 0.8, 0.0, rz + 1.1), (CHUTE_END_X - 0.8, 3.45, rz + 1.1), 0.18, segments=6)
    cylinder(shade, (CHUTE_END_X - 0.8, 0.0, rz - 1.1), (CHUTE_END_X - 0.8, 3.45, rz - 1.1), 0.18, segments=6)
    # Console at the front with buttons, a screen and two floating candy nukes.
    block(console, (0, (CONSOLE_TOP - 0.3) / 2, CONSOLE_Z), (8.6, CONSOLE_TOP - 0.3, 2.0), bevel=0.25)
    block(top, (0, CONSOLE_TOP - 0.15, CONSOLE_Z), (8.9, 0.3, 2.3), bevel=0.1)
    for k, x in enumerate((-1.6, -0.8, 0.0, 0.8)):
        cylinder(buttons, (x, CONSOLE_TOP, CONSOLE_Z - 0.4), (x, CONSOLE_TOP + 0.18, CONSOLE_Z - 0.4), 0.22, segments=8)
    block(shade, (1.9, CONSOLE_TOP + 0.85, CONSOLE_Z + 0.55), (2.2, 1.5, 0.3), bevel=0.06, rot=rot_x(-12))
    block(screen, (1.9, CONSOLE_TOP + 0.9, CONSOLE_Z + 0.37), (1.8, 1.1, 0.1), bevel=0.0, rot=rot_x(-12))
    for x, y in ((-0.4, 0.2), (0.3, -0.2), (0.5, 0.25)):
        p = rot_x(-12) @ Vector((x, y, -0.07)) + Vector((1.9, CONSOLE_TOP + 0.9, CONSOLE_Z + 0.37))
        box(blips, tuple(p), (0.18, 0.18, 0.06), rot=rot_x(-12))
    # W6's moon_nuke (the Moon product), floating 0.4 above the console (Nuke row bob).
    moon_nuke(nuke_body_p, band_l, nuke_fins, (-3.4, CONSOLE_TOP + 0.4, CONSOLE_Z), height=2.0)
    moon_nuke(nuke_body_p, band_r, nuke_fins, (3.6, CONSOLE_TOP + 0.4, CONSOLE_Z - 0.2), height=2.0)
    return m


# ------------------------------------------------------------------------------------------------
# Tethered asteroids, magnets, laser drills, mega asteroid
# ------------------------------------------------------------------------------------------------


def build_tether_rock():
    """A small asteroid floating 7 studs up on a chrome cable from a violet ground anchor. The cable
    reaches 1.2 studs into the rock, so the rock's Float bob (Assembly) never shows a gap."""
    m = Model("M4_TetherRock", "anchor centre on the floor; the rock floats above it", budget=1200)
    anchor = m.piece("Anchor", VIOLET_DARK)
    cable = m.piece("Cable", CHROME_SHADE, material="StudsSmall")
    rock = m.piece("Asteroid", ASTEROID)
    gems_p = m.piece("AsteroidPink", CRYSTAL_PINK)
    gems_c = m.piece("AsteroidCyan", CRYSTAL_CYAN)
    disc(anchor, (0, 0, 0), 1.1, 0.5, segments=10, bevel=0.12)
    cylinder(anchor, (0, 0.45, 0), (0, 1.1, 0), 0.4, segments=8)
    rc = (0.0, 7.2, 0.0)
    cylinder(cable, (0, 1.05, 0), (0, rc[1] - 1.0, 0), 0.1, segments=6)
    asteroid(rock, rc, (2.1, 1.9, 2.0), seed=420, rings=5, segments=9)
    gem_cluster(gems_p, gems_c, (0.4, rc[1] + 1.5, -0.3), scale=0.75, seed=421, count=3)
    return m


def build_gravity_magnet():
    """A big coral horseshoe magnet with chrome tips on a chrome post, holding a little crystal rock
    floating in mid-air below it (the rock Floats; the magnet and post stay still)."""
    m = Model("M4_GravityMagnet", "post base centre on the floor; magnet opens toward -Z", budget=1500)
    base = m.piece("Base", VIOLET)
    post = m.piece("Post", CHROME)
    magnet = m.piece("Magnet", CORAL)
    tips = m.piece("Tips", CHROME_SHADE)
    rock = m.piece("Rock", ASTEROID)
    gems_p = m.piece("RockPink", CRYSTAL_PINK)
    gems_c = m.piece("RockCyan", CRYSTAL_CYAN)
    sparkles = m.piece("Sparkles", SUNNY, material="Smooth")
    disc(base, (0, 0, 0), 1.4, 0.5, segments=10, bevel=0.12)
    cylinder(post, (0, 0.45, 0.9), (0, 6.6, 0.9), 0.3, segments=8)
    bar(post, (0, 6.4, 0.9), (0, 6.4, 0.0), 0.4)
    # Horseshoe: a half ring (tube) in the XZ plane opening toward -Z, at y 6.4, tips pointing down.
    pts = []
    for j in range(9):
        a = math.radians(180 * j / 8)
        pts.append((1.25 * math.cos(a), 6.4, 1.25 * math.sin(a) - 0.6))
    tube(magnet, pts, 0.42, sides=8)
    for s in (-1, 1):
        cylinder(magnet, (s * 1.25, 6.4, -0.6), (s * 1.25, 5.6, -0.7), 0.42, segments=8)
        cylinder(tips, (s * 1.25, 5.62, -0.7), (s * 1.25, 4.9, -0.75), 0.44, segments=8)
    # Floating rock under the tips (its top 1 stud below them: the Float bob never touches them).
    rc = (0.0, 2.6, -0.75)
    asteroid(rock, rc, (1.1, 0.95, 1.05), seed=430, rings=5, segments=8)
    gem_cluster(gems_p, gems_c, (0.2, rc[1] + 0.75, rc[2]), scale=0.55, seed=431, count=3)
    for k in range(3):
        a = 2 * math.pi * k / 3 + 0.4
        star(sparkles, (1.6 * math.cos(a), 3.9 + 0.3 * k, -0.75 + 1.0 * math.sin(a)), 0.22, 0.08, normal=(0, 0, -1))
    return m


def build_laser_drills():
    """Two friendly drill-beam turrets (chrome bases, violet heads, mint nozzles) aiming soft
    translucent beams at a crystal rock in the middle, with sunny sparkle stars where they hit."""
    m = Model("M4_LaserDrills", "rock centre on the floor; turrets either side along X", budget=2500)
    rock = m.piece("Rock", ASTEROID)
    dark = m.piece("RockDark", ASTEROID_DARK)
    pink = m.piece("GemPink", CRYSTAL_PINK)
    cyan = m.piece("GemCyan", CRYSTAL_CYAN)
    base = m.piece("Base", CHROME)
    head = m.piece("Heads", VIOLET)
    nozzle = m.piece("Nozzles", MINT)
    beams = m.piece("Beams", BEAM, material="Smooth", transparency=0.45)
    sparkles = m.piece("Sparkles", SUNNY, material="Smooth")
    floor_rock(rock, (0, 1.4, 0), (2.4, 1.9, 2.1), seed=440, floor=0.0)
    floor_rock(dark, (1.2, 0.6, -1.2), (1.0, 0.8, 0.9), seed=441, floor=0.0)
    gem_cluster(pink, cyan, (0.0, 2.9, 0.1), scale=1.0, seed=442, count=4)
    for s in (-1, 1):
        x = s * 6.0
        disc(base, (x, 0, 0), 1.3, 0.6, segments=10, bevel=0.15)
        cylinder(base, (x, 0.55, 0), (x, 2.4, 0), 0.45, segments=8)
        ellipsoid(head, (x, 2.9, 0), (0.9, 0.75, 0.8), rings=5, segments=8)
        aim = Vector((-s, -0.12, 0)).normalized()
        n0 = Vector((x, 2.9, 0)) + aim * 0.7
        n1 = n0 + aim * 0.9
        cylinder(nozzle, tuple(n0), tuple(n1), 0.3, segments=8, radius_b=0.22)
        hit = Vector((s * 2.2, 2.25, 0))
        cylinder(beams, tuple(n1), tuple(hit), 0.14, segments=6, radius_b=0.26)
        star(sparkles, tuple(hit + Vector((s * 0.15, 0.1, -0.3))), 0.42, 0.1, normal=(s * 0.6, 0.2, -1))
    return m


MEGA_C = (0.0, 20.0, 0.0)  # mega asteroid centre (local)
MEGA_R = (6.2, 5.0, 5.8)


def build_mega_asteroid():
    """
    Hero: a giant lumpy asteroid floating 20 studs up, crowned with big pink / cyan crystals and a
    belt of smaller gems, a sunny ring band round its middle, held by four chrome cables to violet
    ground anchors (each cable reaches 1.5 studs into the rock: FloatBig never shows a gap).
    """
    m = Model("M4_MegaAsteroid", "anchor-square centre on the floor; the asteroid floats at y 20", budget=6000)
    rock = m.piece("Asteroid", ASTEROID)
    dark = m.piece("AsteroidDark", ASTEROID_DARK)
    pink = m.piece("AsteroidPink", CRYSTAL_PINK)
    cyan = m.piece("AsteroidCyan", CRYSTAL_CYAN)
    band = m.piece("AsteroidBand", SUNNY)
    anchors = m.piece("Anchors", VIOLET_DARK)
    cables = m.piece("Cables", CHROME_SHADE, material="StudsSmall")
    asteroid(rock, MEGA_C, MEGA_R, seed=450, rings=8, segments=14, lump=0.16)
    # Darker lumps on the surface (sunk 40 % into the rock).
    for k in range(6):
        a = 2 * math.pi * k / 6 + 0.3
        e = math.radians(-20 + 40 * _hash(k, 451))
        d = Vector((math.cos(a) * math.cos(e), math.sin(e), math.sin(a) * math.cos(e)))
        p = Vector(MEGA_C) + Vector((d.x * MEGA_R[0] * 0.92, d.y * MEGA_R[1] * 0.92, d.z * MEGA_R[2] * 0.92))
        asteroid(dark, tuple(p), (1.3, 1.0, 1.2), seed=452 + k, rings=4, segments=7)
    # Crystal crown on top + a belt of smaller gems.
    gem_cluster(pink, cyan, (0.5, MEGA_C[1] + MEGA_R[1] * 0.8, -0.4), scale=2.4, seed=460, count=6)
    for k in range(5):
        a = 2 * math.pi * k / 5 + 0.9
        d = Vector((math.cos(a), 0.25, math.sin(a)))
        p = Vector(MEGA_C) + Vector((d.x * MEGA_R[0] * 0.85, d.y * MEGA_R[1], d.z * MEGA_R[2] * 0.85))
        gem_cluster(pink, cyan, tuple(p), scale=1.1, seed=470 + k, count=3, up=tuple(d))
    # Tilted sunny ring band round the middle (proud of the rock).
    ring_tube(band, (0, MEGA_C[1] - 0.6, 0), MEGA_R[0] + 0.6, 0.7, 0.5, segments=20)
    # Four cables to the ground anchors.
    for k in range(4):
        a = math.radians(45 + 90 * k)
        g = Vector((7.2 * math.cos(a), 0.0, 7.2 * math.sin(a)))
        disc(anchors, (g.x, 0, g.z), 1.2, 0.55, segments=10, bevel=0.12)
        cylinder(anchors, (g.x, 0.5, g.z), (g.x, 1.3, g.z), 0.45, segments=8)
        top = Vector((MEGA_C[0] + 3.0 * math.cos(a), MEGA_C[1] - MEGA_R[1] * 0.55, MEGA_C[2] + 3.0 * math.sin(a)))
        cylinder(cables, (g.x, 1.25, g.z), tuple(top), 0.14, segments=6)
    return m


# ------------------------------------------------------------------------------------------------
# Ore carts + track + sorter
# ------------------------------------------------------------------------------------------------

LOOP_STRAIGHT = 5.0  # half length of each straight (local z -5 .. 5)
LOOP_R = 8.5  # semicircle radius (straights at local x +-8.5)
RAIL_TOP = 0.3  # rail top above the floor (the carts' pivot height)


def loop_points(offset: float = 0.0, step: float = 1.5):
    """Centreline (+ lateral offset, + = outward) of the oval loop, local; closed (no repeat)."""
    pts = []

    def add_line(x, z0, z1):
        n = max(1, round(abs(z1 - z0) / step))
        for i in range(n):
            pts.append((x, z0 + (z1 - z0) * i / n))

    def add_arc(cz, a0, a1):
        n = max(2, round(abs(math.radians(a1 - a0)) * (LOOP_R + offset) / step))
        for i in range(n):
            a = math.radians(a0 + (a1 - a0) * i / n)
            pts.append(((LOOP_R + offset) * math.cos(a), cz + (LOOP_R + offset) * math.sin(a)))

    r = LOOP_R + offset
    add_line(-r, -LOOP_STRAIGHT, LOOP_STRAIGHT)  # -X straight heading +Z
    add_arc(LOOP_STRAIGHT, 180, 0)  # back semicircle through +Z
    add_line(r, LOOP_STRAIGHT, -LOOP_STRAIGHT)  # +X straight heading -Z
    add_arc(-LOOP_STRAIGHT, 0, -180)  # front semicircle through -Z
    return pts


def build_cart_track():
    """Oval rail loop (two lofted chrome rails on violet sleepers): straights along local Z at
    x +-8.5 (z -5 .. 5) joined by r 8.5 semicircles. Pivot = loop centre on the floor."""
    m = Model("M4_CartTrack", "loop centre on the floor; straights along local Z at x +-8.5", budget=2500)
    rails = m.piece("Rails", CHROME_SHADE, material="StudsSmall")
    sleepers = m.piece("Sleepers", VIOLET_DARK)
    for off in (-0.9, 0.9):
        pts = loop_points(off, step=1.4)
        sections = []
        for i, (x, z) in enumerate(pts + [pts[0]]):
            nx, nz = pts[(i + 1) % len(pts)]
            px, pz = pts[i - 1]
            t = Vector((nx - px, 0.0, nz - pz)).normalized()
            side = Vector((-t.z, 0.0, t.x))
            c = Vector((x, 0.0, z))
            prof = [(-0.11, 0.02), (0.11, 0.02), (0.11, RAIL_TOP), (-0.11, RAIL_TOP)]
            sections.append([tuple(c + side * a + Vector((0, b, 0))) for a, b in prof])
        loft(rails, sections, cap_start=False, cap_end=False)
    pts = loop_points(0.0, step=1.6)
    for i, (x, z) in enumerate(pts):
        nx, nz = pts[(i + 1) % len(pts)]
        t = Vector((nx - x, 0.0, nz - z)).normalized()
        side = Vector((-t.z, 0.0, t.x))
        box(sleepers, (x, 0.08, z), (2.5, 0.14, 0.5), rot=frame_from(side, Vector((0, 1, 0))))
    return m


CART_AXLE_Z = 1.15
WHEEL_R = 0.45


def build_ore_cart():
    """
    Ore cart (routed, R56): a rounded violet hopper with a sunny rim and coral bumpers on two axles.
    Wheels / hubs are ONE piece per axle (WheelsF / HubsF at z -1.15, WheelsR / HubsR at z +1.15),
    each box centred on its axle so VehicleRoutes spins it about local X. Cargo = Ore + OreCyan
    crystals heaped on top. Pivot = rail top centre (wheel bottoms at y 0).
    """
    m = Model("M4_OreCart", "rail top centre (wheel bottoms at y 0); faces -Z", budget=1500)
    body = m.piece("Body", VIOLET)
    rim = m.piece("Rim", SUNNY, material="StudsSmall")
    bumpers = m.piece("Bumpers", CORAL, material="StudsSmall")
    ore = m.piece("Ore", CRYSTAL_PINK)
    ore_c = m.piece("OreCyan", CRYSTAL_CYAN)
    # Hopper (wider at the top) on a chassis plate.
    loft(
        body,
        [
            [(-1.0, 0.75, -1.5), (1.0, 0.75, -1.5), (1.0, 0.75, 1.5), (-1.0, 0.75, 1.5)],
            [(-1.3, 2.05, -1.8), (1.3, 2.05, -1.8), (1.3, 2.05, 1.8), (-1.3, 2.05, 1.8)],
        ],
    )
    block(body, (0, 0.62, 0), (1.6, 0.3, 3.1), bevel=0.06)
    for x0, z0, x1, z1 in ((-1.38, -1.88, 1.38, -1.88), (-1.38, 1.88, 1.38, 1.88), (-1.38, -1.88, -1.38, 1.88), (1.38, -1.88, 1.38, 1.88)):
        bar(rim, (x0, 2.1, z0), (x1, 2.1, z1), 0.24)
    for z in (-2.0, 2.0):
        block(bumpers, (0, 0.95, z), (1.2, 0.5, 0.3), bevel=0.08)
    # Axles: wheels + hubs per axle (box centre on the axle).
    for tag, z in (("F", -CART_AXLE_Z), ("R", CART_AXLE_Z)):
        wheels = m.piece("Wheels" + tag, NAVY, material="Smooth")
        hubs = m.piece("Hubs" + tag, CHROME, material="Smooth")
        for s in (-1, 1):
            cylinder(wheels, (s * 0.78, WHEEL_R, z), (s * 1.08, WHEEL_R, z), WHEEL_R, segments=10)
            cylinder(hubs, (s * 1.08, WHEEL_R, z), (s * 1.16, WHEEL_R, z), 0.2, segments=6)
        cylinder(hubs, (-0.78, WHEEL_R, z), (0.78, WHEEL_R, z), 0.1, segments=6)
    # Crystal cargo heaped on top.
    for k, (x, z) in enumerate(((-0.6, -0.8), (0.5, -0.6), (-0.3, 0.5), (0.6, 0.9), (0.0, -0.1))):
        piece = ore if k % 2 == 0 else ore_c
        crystal(piece, (x, 1.85, z), 1.1 + 0.3 * _hash(k, 480), 0.32, tilt_x=18 * math.sin(k), tilt_z=18 * math.cos(k))
    return m


def build_crystal_sorter():
    """Crystal sorter (front -Z faces the track once placed yaw 90): a long chrome hopper the carts
    tip into, a violet machine with a round glass window full of crystals, a conveyor Belt on top
    and three candy bins (pink / cyan / sunny) at the back."""
    m = Model("M4_CrystalSorter", "ground centre; hopper along local X at the front (-Z)", budget=2500)
    hopper = m.piece("Hopper", CHROME)
    machine = m.piece("Machine", VIOLET)
    trim = m.piece("Trim", SUNNY, material="StudsSmall")
    window = m.piece("Window", GLASS, material="Glass", transparency=0.3)
    belt = m.piece("Belt", NAVY, material="StudsSmall")
    rails = m.piece("Rails", CHROME_SHADE, material="StudsSmall")
    bins_p = m.piece("BinPink", CRYSTAL_PINK)
    bins_c = m.piece("BinCyan", CRYSTAL_CYAN)
    bins_s = m.piece("BinSunny", SUNNY)
    gems_p = m.piece("GemsPink", CRYSTAL_PINK)
    gems_c = m.piece("GemsCyan", CRYSTAL_CYAN)
    # Hopper: an open trough 12 long (local X), lip at y 1.7, front at local z -2.6.
    loft(
        hopper,
        [
            [(-6.0, 1.7, -2.6), (-6.0, 0.4, -1.6), (-6.0, 0.4, -0.6), (-6.0, 1.7, -0.4), (-6.0, 1.7, -0.7), (-6.0, 0.7, -0.85), (-6.0, 0.7, -1.4), (-6.0, 1.7, -2.3)],
            [(6.0, 1.7, -2.6), (6.0, 0.4, -1.6), (6.0, 0.4, -0.6), (6.0, 1.7, -0.4), (6.0, 1.7, -0.7), (6.0, 0.7, -0.85), (6.0, 0.7, -1.4), (6.0, 1.7, -2.3)],
        ],
    )
    for x in (-5.4, 0.0, 5.4):
        block(rails, (x, 0.2, -1.5), (0.4, 0.4, 1.6), bevel=0.06)
    gem_cluster(gems_p, gems_c, (-2.0, 0.9, -1.5), scale=0.7, seed=490, count=3)
    gem_cluster(gems_p, gems_c, (2.6, 0.9, -1.5), scale=0.7, seed=491, count=3)
    # Machine body behind the hopper with a round window of crystals and a conveyor on top.
    block(machine, (0, 2.0, 1.4), (8.0, 4.0, 3.2), bevel=0.35)
    ring_tube(trim, (0, 2.2, -0.21), 1.2, 0.3, 0.2, segments=14, axis="Z")
    cylinder(window, (0, 2.2, -0.16), (0, 2.2, -0.26), 1.08, segments=14)
    box(belt, (0, 4.1, 1.4), (7.0, 0.16, 1.4))
    for z in (0.62, 2.18):
        box(rails, (0, 4.2, z), (7.2, 0.4, 0.24))
    for k, (piece, x) in enumerate(((bins_p, -2.8), (bins_c, 0.0), (bins_s, 2.8))):
        block(piece, (x, 0.7, 4.0), (2.4, 1.4, 1.6), bevel=0.2)
        gem_cluster(gems_p, gems_c, (x, 1.25, 4.0), scale=0.6, seed=495 + k, count=3)
    return m


# ------------------------------------------------------------------------------------------------
# Hover steps + deck
# ------------------------------------------------------------------------------------------------


def build_hover_step():
    """One floating step: a chrome disc with a violet thruster underside and a soft mint glow ring
    (Smooth). The whole model Hovers (Assembly); the layout's collision box stays still."""
    m = Model("M4_HoverStep", "step centre at its underside; placed at its hover height", budget=800)
    top = m.piece("Top", CHROME)
    under = m.piece("Under", VIOLET)
    glow = m.piece("ThrusterGlow", MINT, material="Smooth")
    revolve(under, [(0.0, -0.35), (1.0, -0.35), (1.9, 0.0), (0.0, 0.0)], segments=14)
    disc(top, (0, 0, 0), 2.0, 0.42, segments=14, bevel=0.1)
    ring_tube(glow, (0, -0.3, 0), 0.75, 0.26, 0.14, segments=12)
    return m


def build_hover_deck():
    """Floating lookout deck: a big chrome disc with a violet thruster dome underneath, a sunny
    railing round the back half and a little chrome telescope pointing at the sky."""
    m = Model("M4_HoverDeck", "deck centre at its underside; railing round the back (+Z)", budget=1500)
    top = m.piece("Top", CHROME)
    under = m.piece("Under", VIOLET)
    glow = m.piece("ThrusterGlow", MINT, material="Smooth")
    rail = m.piece("Railing", SUNNY, material="StudsSmall")
    scope = m.piece("Scope", CHROME_SHADE, material="StudsSmall")
    revolve(under, [(0.0, -0.9), (1.4, -0.85), (3.4, 0.0), (0.0, 0.0)], segments=16)
    disc(top, (0, 0, 0), 3.6, 0.5, segments=16, bevel=0.12)
    ring_tube(glow, (0, -0.75, 0), 1.0, 0.3, 0.14, segments=12)
    posts = []
    for k in range(7):
        a = math.radians(-10 + 200 * k / 6)
        p = (3.25 * math.cos(a), 0.45, 3.25 * math.sin(a))
        posts.append(p)
        cylinder(rail, p, (p[0], 1.9, p[2]), 0.12, segments=6)
    for p, q in zip(posts, posts[1:]):
        cylinder(rail, (p[0], 1.8, p[2]), (q[0], 1.8, q[2]), 0.1, segments=6)
    cylinder(scope, (1.2, 0.45, 1.4), (1.2, 1.6, 1.4), 0.12, segments=6)
    cylinder(scope, (1.0, 1.55, 1.7), (1.7, 2.3, 0.7), 0.26, segments=8, radius_b=0.34)
    return m


# ------------------------------------------------------------------------------------------------
# M4_Drillbert — manager NPC (R30)
# ------------------------------------------------------------------------------------------------


def build_drillbert():
    """
    Drillbert (Manager NPC, owner R30): a round chrome robot with mint pixel eyes and smile, a sunny
    hard-hat brim crowned with a coral drill bit, a violet chest panel with candy buttons, chrome
    arms with violet hands, stubby legs with violet feet, and a toy wrench in his right hand.
    Figure ONLY; split into the R30 rig pieces (models/_npc_rig.py).
    """
    from models._npc_rig import rig_split

    m = Model("M4_Drillbert", "feet centre; faces -Z", budget=3000)
    chrome = m.piece("Chrome", CHROME, material="StudsSmall")
    shade = m.piece("Shade", CHROME_SHADE, material="StudsSmall")
    violet = m.piece("Violet", VIOLET, material="StudsSmall")
    face = m.piece("Face", MINT, material="Smooth")
    hat = m.piece("Hat", SUNNY, material="StudsSmall")
    drill = m.piece("Drill", CORAL, material="StudsSmall")
    buttons = m.piece("Buttons", CORAL, material="Smooth")
    wrench = m.piece("Wrench", CHROME_SHADE, material="StudsSmall")
    a = toon_biped(
        {"body": chrome, "head": chrome, "limbs": shade, "hands": violet, "feet": violet},
        head=(1.15, 1.0, 1.05),
        head_shape="dome",
        arm_pose={"right": (24.0, 58.0)},
    )
    # Pixel face on the dome head's front: two mint eyes + a mint smile bar (Smooth, 0.06 proud).
    fz = a["head_front_z"]
    hcy = a["head"][1]
    for s_ in (-1, 1):
        block(face, (s_ * 0.42, hcy + 0.2, fz), (0.36, 0.46, 0.12), bevel=0.04)
    block(face, (0, hcy - 0.3, fz), (0.9, 0.16, 0.12), bevel=0.0)
    for s_ in (-1, 1):
        block(face, (s_ * 0.52, hcy - 0.2, fz), (0.18, 0.18, 0.12), bevel=0.0)
    hc = Vector(a["head"])
    hw, hh, hd = a["head_r"]
    top = a["head_top"]
    # Hard-hat brim + dome, then the drill bit standing up out of it.
    revolve(hat, [(0.0, 0.45), (0.86, 0.42), (1.18, 0.08), (1.25, 0.0), (0.0, 0.0)], center=(0, top - 0.38, hc.z), segments=12)
    revolve(drill, [(0.0, 0.0), (0.5, 0.0), (0.42, 0.55), (0.0, 1.9)], center=(0, top + 0.02, hc.z), segments=8)
    for k in range(2):
        pts = []
        for j in range(6):
            t = j / 5
            ang = math.pi * k + t * 2.0 * math.pi
            r = 0.52 - 0.34 * t
            pts.append((r * math.cos(ang), top + 0.15 + t * 1.3, hc.z + r * math.sin(ang)))
        tube(drill, pts, 0.07, sides=4)
    # Ear bolts.
    for s in (-1, 1):
        cylinder(violet, (s * (hw - 0.1), hc.y, hc.z), (s * (hw + 0.12), hc.y, hc.z), 0.3, segments=8)
    # Chest panel + buttons.
    chest = Vector(a["chest"])
    oriented_ellipsoid(violet, (0, chest.y - 0.1, chest.z + 0.06), (0.75, 0.6, 0.14), normal=(0, 0.1, -1), rings=4, segments=10)
    for k, x in enumerate((-0.32, 0.0, 0.32)):
        oriented_ellipsoid(buttons, (x, chest.y - 0.05, chest.z - 0.06), (0.11, 0.11, 0.05), normal=(0, 0.1, -1), rings=3, segments=6)
    # Toy wrench in the right hand (shaft + open jaw).
    hand = Vector(a["hands"]["right"])
    w0 = hand + Vector((0.0, -0.25, 0.1))
    w1 = hand + Vector((0.1, 1.1, -0.5))
    cylinder(wrench, tuple(w0), tuple(w1), 0.11, segments=6)
    ring_tube(wrench, tuple(w1 + Vector((0.0, 0.28, -0.12))), 0.3, 0.16, 0.18, segments=8, axis="Z")
    rig_split(m, toon_bones(a), assign={"Wrench": "ArmR", "Drill": "Head", "Hat": "Head"}, reach=3.0, frame=((0.0, 0.0, 0.0), 0.0))
    return m


BUILDERS = {
    "M4_Floor": build_floor,
    "M4_EntryArch": build_entry_arch,
    "M4_Rocks": build_rocks,
    "M4_DrillRig": build_drill_rig,
    "M4_TetherRock": build_tether_rock,
    "M4_CartTrack": build_cart_track,
    "M4_OreCart": build_ore_cart,
    "M4_CrystalSorter": build_crystal_sorter,
    "M4_GravityMagnet": build_gravity_magnet,
    "M4_LaserDrills": build_laser_drills,
    "M4_MegaAsteroid": build_mega_asteroid,
    "M4_Drillbert": build_drillbert,
    "M4_HoverStep": build_hover_step,
    "M4_HoverDeck": build_hover_deck,
}
