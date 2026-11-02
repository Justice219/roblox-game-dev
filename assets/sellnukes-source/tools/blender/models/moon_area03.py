"""
moon_area03.py — Moon Base area M3 "UFO Delivery" (spec 2026-10-31-r69-moon-lucky-juice-design §2.2,
owner R70; W7 art-d34): a saucer depot on a crater field. Little UFO couriers park on a raised
landing deck, a glass parcel elevator and a conveyor feed the sorting counter, a tractor-beam pad
catches parcels, a radar dish turns, a fleet of candy saucers hovers on their pads, a star map
shows the routes and a candy-striped launch ring arches over the courier's flight path. Every pad
purchase is its own model set so each one builds in separately; placement lives in
src/shared/Config/Worlds/Moon/Layouts/Area03.luau.

Shared Moon palette + helpers come from W6's models.moon_area01 (crater, moon_arch, moon_nuke,
toon_biped / toon_bones), so all six Moon areas share one look; local helpers here: floor_rock
(flat-bottomed at the floor, R24), crystal, saucer_hull, toon_face. moon_area04.py imports these.

Every model has its OWN pivot (ground centre unless stated, front = -Z). The layout places it with
a slot-local CFrame (identity faces the road); floor-standing models sit at y = 0.4 (floor top).

Models (key: pivot / notes)                                         build key
    M3_Floor         slab centre at ground; top y = 0.4                 base
    M3_EntryArch     ground centre of the walkway opening; double-sided  base
                     "UFO / DELIVERY" (R17), saucer finials
    M3_Rocks         slot origin on the floor top; back rocks, crystals, base
                     antennas; near-road items in RocksL / RocksR pieces
    M3_SaucerDock    PRODUCER "UFO Express": landing deck on 4 legs      M3_SaucerDock
                     (y 10.4), glass parcel elevator, conveyor Belt,
                     sorting counter with floating candy Nukes
    M3_UfoCourier    ROUTED flyer: Body / Dome / Parcel (+ Rim, Lights,  M3_SaucerDock (x2, parked
                     Legs, Pilot, FinL / FinR); pivot = landing feet      on the deck)
    M3_TractorBeam   pad + soft translucent beam + floating BeamRings    M3_TractorBeam
    M3_ParcelPods    two capsule pods with portholes + parcel stack      M3_ParcelPods (x2)
    M3_RadarDish     mast + dish (Dish / DishTrim spin about the mast)   M3_RadarDish
    M3_FleetSaucer   a hovering saucer on its pad (Hull is tinted)       M3_UfoFleet (x3)
    M3_StarMap       star-chart board on a stand                         M3_StarMap
    M3_LaunchRing    candy-striped hoop on two legs (8 arc pieces, so no M3_LaunchRing
                     piece box covers the hole the courier flies through)
    M3_CaptainGlorp  Manager NPC figure ONLY (R30 rig groups)            M3_CaptainGlorp

Animation contract (rows in WorldFxConfig "Moon Base M3/M4" block; routes in VehicleRouteConfig):
    Belt                 M3_SaucerDock conveyor (existing Belt scroll row).
    Nuke*                M3_SaucerDock floating candy nukes (existing Nuke bob row; they float 0.4
                         above the counter, so the bob never sinks them into it).
    Dish / DishTrim      M3_RadarDish: spin about the mast (Assembly -> RadarSpin); a counterweight
                         mirrors the bowl's reach, so both boxes are centred on the mast axis.
    Ship (Assembly)      M3_FleetSaucer: everything but Pad / PadRing hovers (existing Hover row).
    BeamRings            M3_TractorBeam: float up and down (Assembly -> Float).
    FinL / FinR          M3_UfoCourier: the route's "wings" (VehicleRoutes flyer hook), each box
                         balanced onto the body centre line; small wiggle amplitude.
    Static on purpose: Lights (Smooth candy bulbs), Beacon / Core* (small Neon), Beam (translucent).

Glow budget (owner R19): Neon only on the dock beacon and the candy-nuke cores (one small piece each).
Budgets: floor <= 2,500, arch <= 4,500, backdrop <= 4,500, producer <= 6,000, props <= 2,500,
flyer <= 1,500, manager <= 3,000. A fully built M3 stays <= 28k triangles.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import WHITE, Model
from snkit.kit import block, disc, sign_frame
from snkit.shapes import bar, box, cylinder, ellipsoid, prism, revolve, ring_tube, rot_x, rot_y, rot_z

from models._critter_kit import eyes, oriented_ellipsoid, smile, star, tube
from models.area04 import _hash
from models.dino_area03 import FLOOR_TOP, SLOT_D, SLOT_W, balance, boulder, parcel
from models.moon_area01 import (  # W6's shared Moon Base palette + helpers (same look in M1-M6)
    ALIEN_GREEN,
    CHROME,
    CHROME_SHADE,
    CORAL_C,
    INK_M,
    MINT_C,
    MOON_DARK,
    MOON_DUST,
    MOON_GROUND,
    NAVY,
    ROCK_DEEP,
    ROCK_LILAC,
    SUNNY,
    VIOLET,
    crater,
    moon_arch,
    moon_nuke,
    toon_biped,
    toon_bones,
)

# ------------------------------------------------------------------------------------------------
# Moon Base palette: W6's shared palette (models.moon_area01) under the names this module uses, plus
# a few W7 extras (spec §2.2 "Look": pale lilac / moon-grey stud ground, chrome-white + candy
# accents mint / coral / sunshine yellow / violet; NOT Nuke Town's grey-metal hazard look).
# ------------------------------------------------------------------------------------------------

MINT = MINT_C
CORAL = CORAL_C
CRATER = MOON_DARK  # crater bowls
PATH = MOON_DUST  # walkway tiles
MOON_ROCK = ROCK_LILAC
MOON_ROCK_DARK = ROCK_DEEP
EYE = INK_M
MOON_GROUND_DARK = (184, 176, 210)  # dust patches
CRATER_RIM = (224, 218, 240)  # crater rims
VIOLET_DARK = (116, 78, 196)
GLASS = (176, 232, 255)  # Glass material, transparency ~0.35
BEAM = (176, 238, 255)  # soft tractor / drill beams (Smooth, translucent; never Neon)
PARCEL = (222, 168, 104)
CRYSTAL_PINK = (255, 140, 214)
CRYSTAL_CYAN = (110, 230, 255)
# Small Neon accents only (R19).
NEON_CORAL = (255, 120, 110)
NEON_MINT = (120, 255, 200)


# ------------------------------------------------------------------------------------------------
# Local helpers (W6's shared ones are imported above)
# ------------------------------------------------------------------------------------------------


def floor_rock(piece, center, radii, seed: int = 0, floor: float | None = None):
    """
    Lumpy moon rock with an optional flat-bottom floor clamp (dino_area03.boulder): with `floor`
    set it never cuts more than 0.1 into the slab (owner R24), so it can sit half-buried.

    Example: floor_rock(rocks, (30, 1.0, 64), (2.4, 1.6, 2.0), seed=3, floor=0.0)
    """
    boulder(piece, center, radii, seed=seed, rings=4, segments=7, floor=floor)


def crystal(piece, base, height: float, radius: float, tilt_x: float = 0.0, tilt_z: float = 0.0, segments: int = 6):
    """Chunky hexagonal space crystal rooted 0.3 below `base` (never floats), tilted in degrees."""
    tip = min(radius * 1.6, height * 0.45)
    profile = [(0.0, -0.3), (radius * 0.85, -0.3), (radius, 0.0), (radius, height - tip), (0.0, height)]
    revolve(piece, profile, center=base, segments=segments, rot=rot_z(tilt_z) @ rot_x(tilt_x))


def saucer_hull(hull, rim, center, radius: float, thickness: float = 1.1, segments: int = 14):
    """
    Lens-shaped saucer hull (closed revolve: shallow underside + higher domed top) with a rim band
    whose outer face sits 0.1 outside the hull edge. center = the rim-height centre point.

    Example: saucer_hull(body, rim, (0, 1.75, 0), 2.4)
    """
    cx, cy, cz = center
    r = radius
    t = thickness
    revolve(
        hull,
        [(0.0, -0.5 * t), (0.5 * r, -0.45 * t), (0.95 * r, -0.15 * t), (r, 0.0), (0.95 * r, 0.18 * t), (0.62 * r, 0.48 * t), (0.0, 0.55 * t)],
        center=(cx, cy, cz),
        segments=segments,
    )
    ring_tube(rim, (cx, cy, cz), r - 0.05, 0.3, 0.26, segments=segments)


def toon_face(face, shine, a, eye_size: float = 0.27):
    """Glossy eyes + a smile on a toon_biped ROUND head (critter_kit eyes / smile)."""
    eyes(face, shine, a["head"], a["head_r"], yaw=24.0, pitch=8.0, size=eye_size, tall=1.3)
    smile(face, a["head"], a["head_r"], pitch=-24.0, width=22.0, depth=8.0, thickness=0.05, steps=6)


# ------------------------------------------------------------------------------------------------
# Base: floor, entry arch, rocks backdrop
# ------------------------------------------------------------------------------------------------

# Floor craters (floor-local: slot z - 35), kept off the walkway, side path and pad strip.
M3_CRATERS = ((-30, -14, 4.2), (24, -18, 3.4), (42, 2, 3.6), (-24, 22, 3.2), (26, 20, 2.4))


def build_floor():
    """Pale lilac moon-dust slab for the whole slot, darker dust patches, raised-rim craters, a
    chrome-white tile walkway from the road to the counter and a side path to the tractor pad."""
    m = Model("M3_Floor", "slab centre at ground (place at slot (0, 0, 35)); top y = 0.4", budget=2500)
    ground = m.piece("Ground", MOON_GROUND)
    patch = m.piece("Dust", MOON_GROUND_DARK)
    rims = m.piece("CraterRims", CRATER_RIM)
    bowls = m.piece("CraterBowls", CRATER)
    tiles = m.piece("Tiles", PATH)
    block(ground, (0, FLOOR_TOP / 2, 0), (SLOT_W, FLOOR_TOP, SLOT_D - 0.4), bevel=0.15)
    for i, (x, z, sx, sz) in enumerate(((-38, -24, 10, 7), (30, -26, 9, 6), (-46, 26, 7, 8), (44, 12, 6, 8), (-18, -2, 7, 5), (8, 16, 6, 5))):
        # Dust patches top out 0.07 above the floor: never the crater bowls' plane (+0.1, R18).
        block(patch, (x, FLOOR_TOP + 0.01, z), (sx, 0.12, sz), bevel=0.04, rot=rot_y(24 * (_hash(i, 30) - 0.5)))
    for x, z, r in M3_CRATERS:
        crater(rims, bowls, (x, FLOOR_TOP, z), r * 0.8, segments=10)
    # Walkway: two columns of rounded tiles from the road edge (z -35) to the counter (local 3.9).
    z = -34.6
    k = 0
    while z < 3.5:
        length = min(3.6 + 1.0 * _hash(k, 31), 3.9 - z)
        if length < 0.8:
            break
        for s in (-1, 1):
            block(tiles, (s * 2.55, FLOOR_TOP + 0.08, z + length / 2), (4.5, 0.2, length - 0.4), bevel=0.1)
        z += length
        k += 1
    # Side path to the tractor-beam pad (slot x 6 .. 21 at slot z ~31).
    x = 6.2
    k = 0
    while x < 20.8:
        length = 3.4 + 0.8 * _hash(k, 32)
        block(tiles, (x + length / 2, FLOOR_TOP + 0.08, -4.0), (length - 0.4, 0.2, 3.0), bevel=0.1)
        x += length
        k += 1
    return m


def build_entry_arch():
    """W6's shared capsule-post Moon arch (moon_arch: double-sided letters R17, ringed-planet
    finials, crescent crest, small Neon star bulbs) dressed for the depot: "UFO / DELIVERY" in
    sunny letters on navy, coral planets with mint rings."""
    return moon_arch("M3_EntryArch", ["UFO", "DELIVERY"], board=NAVY, planet=CORAL, ring=MINT, band_a=VIOLET, band_b=CORAL)


def build_rocks():
    """Moon rocks, crystal clusters and antenna masts (slot space, pivot = slot origin on the floor
    top). Back items sit at z >= 50; near-road side items live in RocksL / RocksR so no piece box
    covers the producer billboard spot (R31)."""
    m = Model("M3_Rocks", "slot origin on the floor top (place at slot (0, 0.4, 0)); slot-space coordinates", budget=4500)
    rocks = m.piece("Rocks", MOON_ROCK)
    dark = m.piece("RocksDark", MOON_ROCK_DARK)
    pink = m.piece("GemPink", CRYSTAL_PINK)
    cyan = m.piece("GemCyan", CRYSTAL_CYAN)
    masts = m.piece("Masts", CHROME_SHADE, material="StudsSmall")
    balls = m.piece("MastBalls", CORAL, material="Smooth")
    rocks_l = m.piece("RocksL", MOON_ROCK)
    rocks_r = m.piece("RocksR", MOON_ROCK)
    for i, (x, z, rx, ry, rz) in enumerate(((-42, 66, 4.6, 3.6, 3.4), (-24, 67, 3.4, 2.6, 2.8), (-8, 66.5, 2.6, 2.0, 2.4), (10, 67, 3.0, 2.4, 2.6), (27, 66, 4.0, 3.0, 3.0), (44, 65, 4.4, 3.8, 3.6))):
        floor_rock(rocks, (x, ry * 0.45, z), (rx, ry, rz), seed=i + 200, floor=0.0)
        floor_rock(dark, (x + (1.8 if x < 0 else -1.8), ry * 0.3, z - 2.0), (rx * 0.5, ry * 0.5, rz * 0.5), seed=i + 210, floor=0.0)
    # Crystal clusters (pink / cyan) between the rocks.
    for i, (x, z) in enumerate(((-34, 60), (-16, 62), (18, 61), (36, 58), (47, 52), (-47, 54))):
        piece = pink if i % 2 == 0 else cyan
        for k in range(4):
            a = 2 * math.pi * k / 4 + i
            h = 1.6 + 1.6 * _hash(i, k)
            # base 0.3 up: the crystal roots (0.3 below the base) start at the floor; tilted corners dip < 0.1 (R24)
            crystal(piece, (x + 0.7 * math.cos(a), 0.3, z + 0.7 * math.sin(a)), h, 0.38, tilt_x=-20 * math.cos(a), tilt_z=20 * math.sin(a))
    # Antenna masts with candy balls (static).
    for i, (x, z, h) in enumerate(((-30, 63, 9.0), (2, 63.5, 7.0), (31, 62, 8.0))):
        cylinder(masts, (x, 0.0, z), (x, h, z), 0.18, segments=6)
        for y in (h * 0.4, h * 0.7):
            box(masts, (x, y, z), (1.4, 0.14, 0.14))
        ellipsoid(balls, (x, h + 0.3, z), (0.42, 0.42, 0.42), rings=4, segments=8)
    # Near-road side rocks (own pieces, R31).
    for i, z in enumerate((22.0, 36.0)):
        floor_rock(rocks_l, (48.0, 0.7, z), (2.0, 1.4, 1.8), seed=220 + i, floor=0.0)
        floor_rock(rocks_r, (-48.0, 0.7, z + 6.0), (2.0, 1.4, 1.8), seed=230 + i, floor=0.0)
    return m


# ------------------------------------------------------------------------------------------------
# M3_SaucerDock — producer "UFO Express"
# ------------------------------------------------------------------------------------------------

DECK_UNDER = 9.4  # landing deck underside (local y)
DECK_TOP = 10.4  # landing deck top: the couriers park here
DECK_R = 8.5
COUNTER_Z = -9.6  # sorting counter centre (local z)
COUNTER_TOP = 2.7
COURIER_SPOTS = ((4.4, -1.6), (-4.4, 1.6))  # parked couriers (local x, z) on the deck


def build_saucer_dock():
    """
    Producer "UFO Express": a round landing deck on four chrome legs (coral rim band, candy rim
    lights, yellow parking rings for the two couriers, a mint ring round the beacon mast), a glass
    parcel elevator from the ground to the deck with parcels floating inside, a conveyor Belt
    from the elevator to the sorting counter, and the counter with parcels, a radar screen and two
    candy nukes floating above it.
    """
    m = Model("M3_SaucerDock", "deck centre on the floor; counter + conveyor toward -Z (road)", budget=6000)
    chrome = m.piece("Chrome", CHROME)
    shade = m.piece("ChromeShade", CHROME_SHADE, material="StudsSmall")
    feet = m.piece("Feet", VIOLET_DARK)
    rim = m.piece("Rim", CORAL)
    lights = m.piece("Lights", SUNNY, material="Smooth")
    spots = m.piece("Spots", SUNNY, material="StudsSmall")
    mint = m.piece("MintRing", MINT, material="StudsSmall")
    beacon = m.piece("Beacon", NEON_CORAL, material="Neon")
    tube_glass = m.piece("Tube", GLASS, material="Glass", transparency=0.4)
    plinth = m.piece("Plinth", VIOLET)
    belt = m.piece("Belt", NAVY, material="StudsSmall")
    rails = m.piece("Rails", CHROME_SHADE, material="StudsSmall")
    top = m.piece("CounterTop", MINT)
    parcels = m.piece("Parcels", PARCEL, material="StudsSmall")
    ties = m.piece("Ties", CORAL, material="StudsSmall")
    screen = m.piece("Screen", NAVY, material="Smooth")
    blips = m.piece("Blips", NEON_MINT, material="Smooth")
    nuke_body_p = m.piece("NukeBody", ROCK_LILAC, material="StudsSmall")
    nuke_fins = m.piece("NukeFins", CORAL, material="StudsSmall")
    band_l = m.piece("NukeBandL", NEON_MINT, material="Neon")
    band_r = m.piece("NukeBandR", NEON_MINT, material="Neon")

    # Legs (tapered chrome) with violet foot pads.
    for k in range(4):
        a = math.radians(45 + 90 * k)
        d = Vector((math.sin(a), 0.0, -math.cos(a)))
        foot = d * 6.4
        top_p = d * 5.5 + Vector((0, DECK_UNDER + 0.1, 0))
        cylinder(chrome, (foot.x, 0.3, foot.z), tuple(top_p), 0.55, segments=10, radius_b=0.42)
        disc(feet, (foot.x, 0.0, foot.z), 1.0, 0.36, segments=10, bevel=0.1)
    # Deck + rim band + rim lights.
    disc(chrome, (0, DECK_UNDER, 0), DECK_R, DECK_TOP - DECK_UNDER, segments=20, bevel=0.15)
    ring_tube(rim, (0, DECK_UNDER + 0.48, 0), DECK_R + 0.05, 0.5, 0.52, segments=20)
    for k in range(12):
        a = 2 * math.pi * (k + 0.5) / 12
        ellipsoid(lights, ((DECK_R + 0.32) * math.cos(a), DECK_UNDER + 0.48, (DECK_R + 0.32) * math.sin(a)), (0.2, 0.2, 0.2), rings=3, segments=6)
    # Parking rings (0.08 tall on the deck) + the mint beacon ring.
    for x, z in COURIER_SPOTS:
        ring_tube(spots, (x, DECK_TOP + 0.04, z), 1.9, 0.3, 0.08, segments=16)
    ring_tube(mint, (0, DECK_TOP + 0.04, 0), 1.2, 0.3, 0.08, segments=14)
    cylinder(shade, (0, DECK_TOP - 0.05, 0), (0, 13.4, 0), 0.22, segments=8)
    ellipsoid(beacon, (0, 13.75, 0), (0.42, 0.42, 0.42), rings=5, segments=8)
    # Glass parcel elevator (ground -> deck underside) with collars and floating parcels.
    disc(plinth, (0, 0, 0), 2.3, 0.6, segments=14, bevel=0.15)
    cylinder(tube_glass, (0, 0.6, 0), (0, DECK_UNDER, 0), 1.5, segments=14)
    for y in (0.9, DECK_UNDER - 0.3):
        ring_tube(shade, (0, y, 0), 1.6, 0.3, 0.5, segments=14)
    for k, (y, yaw) in enumerate(((3.4, 15), (6.4, -25))):
        parcel(parcels, ties, (0, y, 0), (1.3, 1.0, 1.1), yaw=yaw)
    # Conveyor from the elevator plinth to the back of the counter (Belt scrolls along local Z).
    bz0, bz1 = -2.4, COUNTER_Z + 1.2
    blen = bz0 - bz1
    box(belt, (0, 1.2, (bz0 + bz1) / 2), (1.4, 0.16, blen))
    for x in (-0.82, 0.82):
        box(rails, (x, 1.28, (bz0 + bz1) / 2), (0.24, 0.4, blen + 0.2))
        for z in (bz0 - 0.6, bz1 + 0.6):
            box(rails, (x, 0.55, z), (0.24, 1.1, 0.24))
    parcel(parcels, ties, (0, 1.85, -5.2), (1.1, 0.8, 0.9), yaw=8, bow=False)
    # Sorting counter: chrome body + mint top, parcels, a radar screen, two floating candy nukes.
    block(chrome, (0, (COUNTER_TOP - 0.3) / 2, COUNTER_Z), (10.0, COUNTER_TOP - 0.3, 2.2), bevel=0.25)
    block(top, (0, COUNTER_TOP - 0.15, COUNTER_Z), (10.3, 0.3, 2.5), bevel=0.1)
    parcel(parcels, ties, (-1.6, COUNTER_TOP + 0.42, COUNTER_Z + 0.2), (1.2, 0.84, 1.0), yaw=-10)
    parcel(parcels, ties, (1.3, COUNTER_TOP + 0.36, COUNTER_Z + 0.1), (1.0, 0.72, 0.9), yaw=14)
    block(shade, (0, COUNTER_TOP + 0.9, COUNTER_Z + 0.65), (2.4, 1.6, 0.3), bevel=0.06, rot=rot_x(-12))
    block(screen, (0, COUNTER_TOP + 0.94, COUNTER_Z + 0.47), (2.0, 1.2, 0.1), bevel=0.0, rot=rot_x(-12))
    for k, (x, y) in enumerate(((-0.5, 0.25), (0.3, -0.15), (0.6, 0.3))):
        p = Vector((x, y, -0.07))
        p = rot_x(-12) @ p + Vector((0, COUNTER_TOP + 0.94, COUNTER_Z + 0.47))
        box(blips, tuple(p), (0.18, 0.18, 0.06), rot=rot_x(-12))
    # W6's moon_nuke (the Moon product), floating 0.4 above the counter (Nuke row bob never sinks them).
    moon_nuke(nuke_body_p, band_l, nuke_fins, (-3.7, COUNTER_TOP + 0.4, COUNTER_Z), height=2.0)
    moon_nuke(nuke_body_p, band_r, nuke_fins, (3.7, COUNTER_TOP + 0.4, COUNTER_Z), height=2.0)
    return m


# ------------------------------------------------------------------------------------------------
# M3_UfoCourier — routed flyer
# ------------------------------------------------------------------------------------------------

UFO_RIM_Y = 1.75  # saucer rim height: the fins' hinge line
UFO_R = 2.4


def _fin(piece, side: int):
    """Stubby violet fin with a ball tip, flat at the rim height (box centred on y = UFO_RIM_Y)."""
    shape = [(UFO_R - 0.5, 0.45), (UFO_R + 0.55, 0.3), (UFO_R + 0.85, -0.1), (UFO_R + 0.4, -0.45), (UFO_R - 0.5, -0.35)]
    prism(piece, [(side * u, UFO_RIM_Y, -v) for u, v in shape], (0, 1, 0), 0.16)
    ellipsoid(piece, (side * (UFO_R + 0.95), UFO_RIM_Y, 0.0), (0.22, 0.22, 0.22), rings=4, segments=6)


def build_ufo_courier():
    """
    UFO Express courier (routed: VehicleRoutes flies the whole model, R25): a chrome saucer with a
    coral rim band, candy rim lights, a glass dome with a tiny green pilot waving through it, three
    landing legs and a parcel held under its belly. Pivot = landing feet (it parks on the deck).
    FinL / FinR are the route's flyer "wings", balanced about the centre line.
    """
    m = Model("M3_UfoCourier", "landing feet centre (parks on the deck); faces -Z", budget=1500)
    body = m.piece("Body", CHROME, material="StudsSmall")
    rim = m.piece("Rim", CORAL, material="StudsSmall")
    lights = m.piece("Lights", SUNNY, material="Smooth")
    dome = m.piece("Dome", GLASS, material="Glass", transparency=0.35)
    pilot = m.piece("Pilot", ALIEN_GREEN, material="Smooth")
    pilot_eyes = m.piece("PilotEyes", EYE, material="Smooth")
    legs = m.piece("Legs", CHROME_SHADE, material="StudsSmall")
    fin_l = m.piece("FinL", VIOLET, material="StudsSmall")
    fin_r = m.piece("FinR", VIOLET, material="StudsSmall")
    box_p = m.piece("Parcel", PARCEL, material="StudsSmall")
    tie = m.piece("ParcelTie", CORAL, material="StudsSmall")
    saucer_hull(body, rim, (0, UFO_RIM_Y, 0), UFO_R, thickness=1.1)
    for k in range(8):
        a = 2 * math.pi * (k + 0.5) / 8
        ellipsoid(lights, ((UFO_R + 0.12) * math.cos(a), UFO_RIM_Y, (UFO_R + 0.12) * math.sin(a)), (0.16, 0.16, 0.16), rings=3, segments=6)
    revolve(dome, [(0.0, 0.0), (1.1, 0.0), (1.0, 0.45), (0.62, 0.88), (0.0, 1.02)], center=(0, UFO_RIM_Y + 0.45, 0), segments=12)
    ellipsoid(pilot, (0, UFO_RIM_Y + 0.85, -0.05), (0.42, 0.4, 0.4), rings=5, segments=8)
    for s in (-1, 1):
        oriented_ellipsoid(pilot_eyes, (s * 0.15, UFO_RIM_Y + 0.92, -0.4), (0.09, 0.12, 0.05), normal=(s * 0.3, 0.1, -1), rings=3, segments=6)
    # Landing legs + round feet + the parcel clamp.
    for k in range(3):
        a = math.radians(90 + 120 * k)
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        top_p = d * 1.25 + Vector((0, UFO_RIM_Y - 0.45, 0))
        foot = d * 1.75 + Vector((0, 0.14, 0))
        cylinder(legs, tuple(top_p), tuple(foot), 0.12, segments=6)
        ellipsoid(legs, tuple(foot), (0.3, 0.12, 0.3), rings=3, segments=6)
    cylinder(legs, (0, UFO_RIM_Y - 0.5, 0), (0, 1.12, 0), 0.24, segments=6)
    parcel(box_p, tie, (0, 0.62, 0), (1.3, 1.0, 1.1), bow=False)
    # Fins, each balanced onto the centre line (the cube lands inside the opposite fin's ball tip).
    _fin(fin_l, -1)
    _fin(fin_r, 1)
    balance(fin_l, (0.0, UFO_RIM_Y, 0.0), axes=(0,), free=(0.0, UFO_RIM_Y, 0.0))
    balance(fin_r, (0.0, UFO_RIM_Y, 0.0), axes=(0,), free=(0.0, UFO_RIM_Y, 0.0))
    return m


# ------------------------------------------------------------------------------------------------
# Small builds
# ------------------------------------------------------------------------------------------------

BEAM_TOP = 6.0  # tractor beam top (local y): couriers hover above it


def build_tractor_beam():
    """Tractor-beam pad: chrome base, violet ring with candy lights, navy plate, a soft translucent
    column of light (Beam, Smooth, never Neon) with three floating BeamRings and a parcel in it."""
    m = Model("M3_TractorBeam", "ground centre; beam rises to y 6", budget=2000)
    base = m.piece("Base", CHROME)
    ring = m.piece("Ring", VIOLET)
    plate = m.piece("Plate", NAVY, material="StudsSmall")
    lights = m.piece("Lights", SUNNY, material="Smooth")
    beam = m.piece("Beam", BEAM, material="Smooth", transparency=0.6)
    rings = m.piece("BeamRings", WHITE, material="Smooth", transparency=0.25)
    parcels = m.piece("Parcels", PARCEL, material="StudsSmall")
    ties = m.piece("Ties", CORAL, material="StudsSmall")
    disc(base, (0, 0, 0), 6.2, 0.5, segments=18, bevel=0.15)
    ring_tube(ring, (0, 0.6, 0), 5.6, 0.9, 0.3, segments=18)
    disc(plate, (0, 0.46, 0), 5.0, 0.16, segments=18, bevel=0.04)
    for k in range(6):
        a = 2 * math.pi * (k + 0.5) / 6
        ellipsoid(lights, (5.6 * math.cos(a), 0.82, 5.6 * math.sin(a)), (0.24, 0.16, 0.24), rings=3, segments=6)
    cylinder(beam, (0, 0.64, 0), (0, BEAM_TOP, 0), 4.0, segments=16, radius_b=3.4)
    for y in (1.8, 3.4, 5.0):
        r = 4.0 + (3.4 - 4.0) * (y - 0.64) / (BEAM_TOP - 0.64) + 0.18
        ring_tube(rings, (0, y, 0), r, 0.16, 0.14, segments=16)
    parcel(parcels, ties, (0, 2.6, 0), (1.3, 1.0, 1.1), yaw=20)
    return m


def build_parcel_pods():
    """Two capsule pods (chrome, coral band, glass porthole) and a small parcel stack (placed x2)."""
    m = Model("M3_ParcelPods", "ground centre; portholes face -Z", budget=1500)
    chrome = m.piece("Chrome", CHROME)
    band = m.piece("Bands", CORAL)
    feet = m.piece("Feet", VIOLET_DARK)
    port = m.piece("Portholes", GLASS, material="Glass", transparency=0.3)
    parcels = m.piece("Parcels", PARCEL, material="StudsSmall")
    ties = m.piece("Ties", MINT, material="StudsSmall")
    for (x, z, r, h) in ((-1.1, 0.3, 1.15, 3.6), (1.5, -0.4, 0.95, 2.8)):
        disc(feet, (x, 0, z), r + 0.25, 0.3, segments=12, bevel=0.08)
        revolve(chrome, [(0.0, 0.3), (r * 0.9, 0.3), (r, 0.6), (r, h - r * 0.4), (r * 0.7, h - 0.05), (0.0, h + 0.1)], center=(x, 0, z), segments=12)
        ring_tube(band, (x, h * 0.32, z), r + 0.05, 0.36, 0.3, segments=12)
        # Porthole on the front (-Z) face, 0.08 proud of the hull.
        cylinder(band, (x, h * 0.62, z - r + 0.05), (x, h * 0.62, z - r - 0.12), 0.48, segments=10)
        cylinder(port, (x, h * 0.62, z - r - 0.1), (x, h * 0.62, z - r - 0.18), 0.36, segments=10)
    parcel(parcels, ties, (1.6, 0.5, 1.5), (1.2, 1.0, 1.1), yaw=-10)
    parcel(parcels, ties, (1.5, 1.48, 1.45), (0.9, 0.8, 0.85), yaw=16)
    return m


DISH_Y = 9.4  # dish hub height on the mast (local)


def build_radar_dish():
    """
    Violet base, chrome mast with rungs, and a radar dish that turns about the mast. Everything that
    spins is ONE chrome piece (Dish: bowl, hub, feed arm + receiver ball, and a counterweight whose
    back face mirrors the bowl's front reach) plus a coral hub ring (DishTrim, symmetric about the
    mast), so both pieces' box centres sit on the mast axis without any balance cube.
    """
    from snkit.core import br

    m = Model("M3_RadarDish", "mast base centre on the floor; dish spins about the mast", budget=1500)
    base = m.piece("Base", VIOLET)
    mast = m.piece("Mast", CHROME_SHADE)
    rungs = m.piece("Rungs", VIOLET_DARK, material="StudsSmall")
    dish = m.piece("Dish", CHROME)
    trim = m.piece("DishTrim", CORAL, material="StudsSmall")
    disc(base, (0, 0, 0), 1.8, 0.7, segments=12, bevel=0.15)
    cylinder(mast, (0, 0.65, 0), (0, DISH_Y - 0.5, 0), 0.32, segments=8, radius_b=0.26)
    for y in (2.4, 4.6, 6.8):
        ring_tube(rungs, (0, y, 0), 0.4, 0.18, 0.2, segments=8)
    # Bowl tilted 35 deg up, facing local -Z, hub on the mast axis; feed arm + receiver ball.
    tilt = rot_x(-(90 - 35))  # bowl normal (0, cos 55, -sin 55): up and toward -Z (the road)
    revolve(dish, [(0.0, 0.0), (0.9, 0.1), (1.9, 0.45), (2.6, 0.95), (2.45, 1.05), (1.8, 0.62), (0.85, 0.3), (0.0, 0.22)], center=(0, DISH_Y, 0), segments=16, rot=tilt)
    cylinder(dish, (0, DISH_Y - 0.5, 0), (0, DISH_Y + 0.1, 0), 0.5, segments=8)
    axis = tilt @ Vector((0, 1, 0))
    hub = Vector((0, DISH_Y, 0))
    bar(dish, tuple(hub + axis * 0.3), tuple(hub + axis * 2.0), 0.14)
    ellipsoid(dish, tuple(hub + axis * 2.15), (0.32, 0.32, 0.32), rings=4, segments=8)
    # Counterweight behind the hub: its back face sits at -(front reach), so the box is centred.
    zs = [br(v.co)[2] for v in dish.bm.verts]
    front = min(zs)
    back = 0.9
    cw_depth = (-front) - back
    bar(dish, (0, DISH_Y, 0.2), (0, DISH_Y, back), 0.3)
    block(dish, (0, DISH_Y, back + cw_depth / 2), (1.3, 1.0, cw_depth), bevel=0.12)
    ring_tube(trim, (0, DISH_Y - 0.2, 0), 0.62, 0.24, 0.3, segments=10)
    return m


def build_fleet_saucer():
    """One fleet saucer hovering 1.6 above its pad (Hull is TINTED per placement: three candy
    colours in the layout). Everything but Pad / PadRing hovers as one Assembly."""
    m = Model("M3_FleetSaucer", "pad centre on the floor; saucer hovers above it", budget=1500)
    pad = m.piece("Pad", CHROME_SHADE)
    pad_ring = m.piece("PadRing", MINT, material="StudsSmall")
    hull = m.piece("Hull", WHITE, tinted=True)
    trim = m.piece("HullTrim", CHROME, material="StudsSmall")
    lights = m.piece("Lights", SUNNY, material="Smooth")
    dome = m.piece("Dome", GLASS, material="Glass", transparency=0.35)
    pilot = m.piece("Pilot", ALIEN_GREEN, material="Smooth")
    pilot_eyes = m.piece("PilotEyes", EYE, material="Smooth")
    disc(pad, (0, 0, 0), 2.9, 0.35, segments=16, bevel=0.1)
    ring_tube(pad_ring, (0, 0.39, 0), 2.4, 0.32, 0.08, segments=16)
    y = 2.6
    saucer_hull(hull, trim, (0, y, 0), 2.7, thickness=1.2)
    for k in range(8):
        a = 2 * math.pi * k / 8
        ellipsoid(lights, (2.82 * math.cos(a), y, 2.82 * math.sin(a)), (0.17, 0.17, 0.17), rings=3, segments=6)
    revolve(dome, [(0.0, 0.0), (1.2, 0.0), (1.08, 0.5), (0.66, 0.95), (0.0, 1.1)], center=(0, y + 0.5, 0), segments=12)
    ellipsoid(pilot, (0, y + 0.95, -0.05), (0.45, 0.42, 0.42), rings=5, segments=8)
    for s in (-1, 1):
        oriented_ellipsoid(pilot_eyes, (s * 0.16, y + 1.02, -0.43), (0.1, 0.13, 0.05), normal=(s * 0.3, 0.1, -1), rings=3, segments=6)
    return m


def build_star_map():
    """Star chart on a chrome stand: a navy panel in a violet frame with candy stars, a ringed
    planet, two little planets, a dotted route and a mini saucer at its end (raised layers, R18)."""
    m = Model("M3_StarMap", "ground centre; chart faces -Z", budget=1500)
    stand = m.piece("Stand", CHROME_SHADE)
    feet = m.piece("Feet", VIOLET_DARK)
    frame = m.piece("Frame", VIOLET)
    panel = m.piece("Panel", NAVY, material="Smooth")
    stars = m.piece("Stars", SUNNY, material="Smooth")
    coral = m.piece("PlanetCoral", CORAL, material="Smooth")
    mint = m.piece("PlanetMint", MINT, material="Smooth")
    dots = m.piece("Route", WHITE, material="Smooth")
    for x in (-3.6, 3.6):
        cylinder(stand, (x, 0.3, 0.15), (x, 6.9, 0.15), 0.28, segments=8)
        disc(feet, (x, 0, 0.15), 0.8, 0.32, segments=10, bevel=0.08)
    cy, w, h, depth = 4.6, 7.8, 4.8, 0.5
    sign_frame(frame, panel, (0, cy, 0), (w, h), border=0.4, depth=depth)
    face = -depth * 0.35
    ink = 0.06

    def at(x: float, y: float, layer: int = 0) -> tuple:
        return (x, cy + y, face - ink / 2 - 0.03 * layer)

    for k, (x, y, s) in enumerate(((-3.0, 1.6, 0.32), (-1.2, 1.9, 0.22), (2.9, 1.7, 0.26), (-2.6, -1.5, 0.24), (0.6, -1.8, 0.2), (3.1, -0.4, 0.22), (-0.4, 1.2, 0.16))):
        star(stars, at(x, y), s, ink, normal=(0, 0, -1))
    # Ringed planet (coral disc + mint ring on a higher layer) and two small planets.
    cylinder(coral, (1.6, cy + 0.5, face - 0.0), (1.6, cy + 0.5, face - ink), 0.75, segments=14)
    ring_tube(mint, (1.6, cy + 0.5, face - ink - 0.03), 1.05, 0.18, ink, segments=16, axis="Z")
    cylinder(mint, (-2.7, cy - 0.2, face), (-2.7, cy - 0.2, face - ink), 0.42, segments=12)
    cylinder(coral, (-0.6, cy - 1.1, face), (-0.6, cy - 1.1, face - ink), 0.3, segments=10)
    # Dotted route arcing from the mint planet toward the ringed one (layer 1: above the panel).
    for k in range(6):
        t = (k + 1) / 7
        x = -2.15 + t * (0.75 + 2.15)
        y = -0.1 + t * 0.3 + 0.7 * math.sin(t * math.pi)
        box(dots, at(x, y, 1), (0.18, 0.18, ink))
    return m


RING_Y = 16.0  # launch ring centre height (local)
RING_R = 6.4
RING_T = 0.45


def build_launch_ring():
    """
    Candy-striped launch ring: eight 45-degree arc pieces (coral / sunny) on two chrome legs with
    violet feet. Split into arcs + one piece per leg ON PURPOSE: the routed courier flies through
    the hole, and no piece's bounding box may cover it (tests/vehicle-routes.luau flyer clearance).
    """
    m = Model("M3_LaunchRing", "ground centre under the ring; ring plane faces -Z (road)", budget=2000)
    arcs = []
    for k in range(8):
        name = f"RingA{k // 2 + 1}" if k % 2 == 0 else f"RingB{k // 2 + 1}"
        colour = CORAL if k % 2 == 0 else SUNNY
        arcs.append(m.piece(name, colour))
    for k, piece in enumerate(arcs):
        pts = []
        for j in range(5):
            a = math.radians(45 * k + 45 * j / 4)
            pts.append((RING_R * math.cos(a), RING_Y + RING_R * math.sin(a), 0.0))
        tube(piece, pts, RING_T, sides=8)
    for side, name in ((-1, "LegL"), (1, "LegR")):
        leg = m.piece(name, CHROME)
        foot = m.piece(f"Foot{name[-1]}", VIOLET_DARK)
        x0 = side * (RING_R + 0.9)
        cylinder(leg, (x0, 0.4, 0), (side * (RING_R + 0.2), RING_Y - 0.6, 0), 0.4, segments=8, radius_b=0.32)
        disc(foot, (x0, 0, 0), 1.1, 0.42, segments=10, bevel=0.1)
    return m


# ------------------------------------------------------------------------------------------------
# M3_CaptainGlorp — manager NPC (R30)
# ------------------------------------------------------------------------------------------------


def build_captain_glorp():
    """
    Captain Glorp (Manager NPC, owner R30): a round green pilot alien with big glossy eyes, two
    bobble antennae, a violet flying cap with chrome goggles pushed up, a sunny scarf, a coral
    flight jacket with a star badge, navy trousers + violet boots, and a parcel scanner in his
    right hand. Figure ONLY; split into the R30 rig pieces (models/_npc_rig.py).
    """
    from models._npc_rig import rig_split

    m = Model("M3_CaptainGlorp", "feet centre; faces -Z", budget=3000)
    skin = m.piece("Skin", ALIEN_GREEN, material="StudsSmall")
    jacket = m.piece("Jacket", CORAL, material="StudsSmall")
    pants = m.piece("Pants", NAVY, material="StudsSmall")
    boots = m.piece("Boots", VIOLET_DARK, material="StudsSmall")
    face = m.piece("Face", EYE, material="Smooth")
    shine = m.piece("Shine", WHITE, material="Smooth")
    sunny = m.piece("Sunny", SUNNY, material="StudsSmall")
    cap = m.piece("Cap", VIOLET, material="StudsSmall")
    goggles = m.piece("Goggles", CHROME_SHADE, material="StudsSmall")
    lenses = m.piece("Lenses", GLASS, material="Smooth")
    scanner = m.piece("Scanner", CHROME, material="StudsSmall")
    scanner_screen = m.piece("ScannerScreen", MINT, material="Smooth")
    a = toon_biped(
        {"body": jacket, "head": skin, "limbs": skin, "hands": skin, "feet": boots},
        head=(1.2, 1.08, 1.1),
        arm_pose={"right": (-14.0, 72.0)},
    )
    toon_face(face, shine, a)
    # Navy trousers over the legs (0.06 proud of the limb cylinders).
    for sx in (-1, 1):
        cylinder(pants, (sx * a["leg_x"], 0.7, 0.0), (sx * a["leg_x"], a["hip"] + 0.1, 0.0), 0.4, segments=8)
    hc = Vector(a["head"])
    hw, hh, hd = a["head_r"]
    top = a["head_top"]
    # Flying cap (a dome hugging the head top) with ear flaps, goggles pushed up on its front.
    revolve(cap, [(0.0, 0.62), (0.78, 0.58), (1.08, 0.24), (1.12, 0.0), (0.0, 0.0)], center=(0, top - 0.55, hc.z + 0.02), segments=12)
    for s in (-1, 1):
        oriented_ellipsoid(cap, (s * (hw - 0.02), hc.y + 0.1, hc.z + 0.1), (0.36, 0.5, 0.16), normal=(s, 0, 0), rings=4, segments=8)
    ring_tube(goggles, (0, top - 0.42, hc.z + 0.02), 1.15, 0.16, 0.2, segments=12)
    for s in (-1, 1):
        c = Vector((s * 0.4, top - 0.32, hc.z - 1.02))
        oriented_ellipsoid(goggles, tuple(c), (0.34, 0.3, 0.14), normal=(s * 0.25, 0.35, -1), rings=4, segments=8)
        oriented_ellipsoid(lenses, tuple(c + Vector((s * 0.02, 0.03, -0.09))), (0.25, 0.22, 0.06), normal=(s * 0.25, 0.35, -1), rings=3, segments=8)
    # Bobble antennae out of the cap.
    for s in (-1, 1):
        base = (s * 0.45, top - 0.05, hc.z + 0.25)
        tip = (s * 0.95, top + 1.0, hc.z + 0.45)
        tube(skin, [base, (s * 0.7, top + 0.55, hc.z + 0.35), tip], 0.08, sides=5)
        ellipsoid(sunny, tip, (0.22, 0.22, 0.22), rings=4, segments=6)
    # Scarf round the neck with a tail streaming back + a star badge on the jacket.
    neck = a["neck"]
    ring_tube(sunny, (0, neck - 0.05, 0.05), 0.95, 0.3, 0.34, segments=12)
    tube(sunny, [(0.55, neck - 0.1, 0.75), (0.8, neck - 0.35, 1.3), (1.0, neck - 0.75, 1.65)], 0.16, sides=4, radii=[0.18, 0.15, 0.1])
    chest = Vector(a["chest"])
    star(sunny, (-0.5, chest.y + 0.05, chest.z - 0.04), 0.26, 0.12, normal=(0, 0, -1))
    # Parcel scanner in the right hand.
    hand = Vector(a["hands"]["right"])
    block(scanner, tuple(hand + Vector((-0.2, 0.25, -0.35))), (0.9, 0.62, 0.22), bevel=0.06, rot=rot_x(-20))
    block(scanner_screen, tuple(hand + Vector((-0.2, 0.27, -0.47))), (0.7, 0.44, 0.06), bevel=0.0, rot=rot_x(-20))
    rig_split(
        m,
        toon_bones(a),
        assign={"Scanner": "ArmR", "ScannerScreen": "ArmR"},
        reach=3.0,
        frame=((0.0, 0.0, 0.0), 0.0),
    )
    return m


BUILDERS = {
    "M3_Floor": build_floor,
    "M3_EntryArch": build_entry_arch,
    "M3_Rocks": build_rocks,
    "M3_SaucerDock": build_saucer_dock,
    "M3_UfoCourier": build_ufo_courier,
    "M3_TractorBeam": build_tractor_beam,
    "M3_ParcelPods": build_parcel_pods,
    "M3_RadarDish": build_radar_dish,
    "M3_FleetSaucer": build_fleet_saucer,
    "M3_StarMap": build_star_map,
    "M3_LaunchRing": build_launch_ring,
    "M3_CaptainGlorp": build_captain_glorp,
}
