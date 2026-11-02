"""
moon_base.py — Moon Base's world frame: the Landing Plaza hub, the 8 plot frames, the moon scenery
and the far planet backdrop (W9b, owner R70; spec
docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §2.1 / §2.3 "Look"). The rocket
portal that stands in the lobby AND at the Landing Plaza is hub_moon_rocket.py.

WORLD-LOCAL frame (relative to Moon Base's world origin, WorldGeometry "moon" = (-6000, 0, 0); the
layout is src/shared/Config/Worlds/Moon/MoonHubLayout.luau, which mirrors every constant below).
The ring is EXACTLY Dino Valley's (dino_valley.py), so WorldLayout, AreaLayouts, the plot builder
and the billboard solver reuse the contract unchanged:
    Landing Plaza centre at (0, 0, 0), ground top y = 0; plots i = 1..8 at yaw (i-1)*45° with their
    origin at radius 260, plot length 312 (3 rows, 6 slots).
    Layers (z-fight rule R18: never two walk surfaces on one plane, curved seams only between
    different heights):
        Moon_Ground         r 0..662   top -0.40   far moon floor (under everything, past the ridge)
        Moon_LandingPlaza   r 0..244   top  0.00   pale lilac moon dust
                            craters    rim 0.08 / floor 0.03 (little dimples between the trails)
                            r 25.6..88 top  0.18   chrome landing-pad ring (+ violet tiles 0.24)
                            welcome walk (yaw 22.5, r 87.6..122) top 0.12
        Moon_RingPath x8    r 230..260 top  0.06   periwinkle ring path (straight 20-stud mouth at
                                                   each plot entrance so the plot path butts it)
        Moon_Trail x8       r 87.4..236 top 0.12   periwinkle trail from the plaza to each plot
        Moon_PlotGround     plot-local top 0.00    (different height from the ring path: no seam)
        Moon_Path           plot-local top 0.06 (+ chrome edging 0.40, light tiles 0.09)
    Boundary: Moon_BoundaryRidge x8 (45° crater-wall arcs) foot r 652 leaning in to r 644 at the
    top, invisible collision ring at r 650 (MoonHubLayout), the far planets at r 765 high in the sky.

Models (pivot / front; HubBuilder-style placement in MoonHubLayout):
    Landing Plaza + frame
        Moon_Ground          world-local origin; far moon floor disc (StudsLarge), persistent
        Moon_LandingPlaza    world-local origin; dust, craters, chrome plaza ring + tiles, walk
        Moon_RingPath        world-local origin, arc centred on +Z (spawn at yaw (i-1)*45)
        Moon_Trail           world-local origin, trail along +Z (spawn at yaw (i-1)*45); `Lights`
                             TINTED with the plot colour
        Moon_RocketFountain  pool centre on the ground; a friendly smiling rocket statue faces -Z on
                             a moon-rock island and three "star water" jets arc from its fins into
                             the pool (`Ripple` rings bob via WorldFx, `Sparkles` float on the water)
        Moon_TitleSign       ground centre between the posts; "MOON BASE" letters on BOTH faces
        Moon_TeleportPad     ground centre; pad top y 1.0; Label (7.3 x 2.6) front face z = 5.97
                             faces -Z; board top y 9.0 (Hub_Digit<i> stands at (0, 9.0, 6.45));
                             `Accent` TINTED. Same anchor numbers as Hub_TeleportPad.
        Moon_EggStand        ground centre; egg pivot (0, 4.0, 0) in a crater cup; Sign (9.2 x 3.2)
                             front face z = 2.72; `Accent` TINTED. Same numbers as Hub_EggStand.
        Moon_Leaderboard     ground centre; chrome monitor, Screen (12.8 x 17.8) front face
                             z = -0.25 at y 12.9; `Frame` TINTED. Same numbers as Hub_Leaderboard.
    Plot frame (PLOT-LOCAL: origin = entrance centre on the ring path, +Z away from the plaza)
        Moon_PlotGround      two moon-dust plates x in [-80,-10] / [10,80], curved front, back z 312
        Moon_Path            periwinkle path |x| <= 8 (z 0..312.6), chrome edging 8..10 (top 0.4),
                             landing-light tiles down the middle
        Moon_CraterRim       rocky crater rim just OUTSIDE the footprint (x = +-[80.2, 82.6],
                             z = [312.2, 314.6]); `Lights` TINTED (plot colour)
        Moon_EntranceArch    plot-local (0, 0, 4): chrome towers at x = +-13 (5 x 5 footprint like
                             Plot_EntranceArch), a twin girder beam carrying the cream `OwnerSign`
                             panels front z = -1.85 / back z = +1.85 (22 x 3.6) for the
                             "<Name>'s Moon Nukes" SurfaceGui; `Accent` TINTED; a toy rocket on top
        Moon_LockedSlot      SLOT-local; a space-barrier fence across the slot front, the "COMING
                             SOON" board (`Sign`, front face z = 4.19 like Plot_LockedSlot) and a
                             landed supply capsule waiting to open
    Scenery (ground pivot, front -Z)
        Moon_Crater, Moon_Rock, Moon_CrystalCluster (violet + mint crystals: `Crystal*` pieces glow
        softly via WorldFx), Moon_Antenna (comms mast: `Dish` sweeps, `Bulb` blinks softly),
        Moon_BoundaryRidge (45° crater-wall arc, world-local origin, centred on +Z),
        Moon_PlanetBackdrop (far, low-poly: a big ringed planet + a cartoon blue-green home planet)

Budgets (docs/world-art.md §4; Moon hub first view <= 700 MeshParts / 150k triangles / <= 45 unique
meshes, measured in tests/moon-hub-layout.luau): floors <= 3,500, fixtures <= 3,000, hero (fountain,
title sign) <= 6,000, ridge <= 3,000 per arc, planets <= 2,500.

Kid-friendly (spec §2.2 "Look"): pale lilac / moon-grey stud ground, chrome-white + candy accents
(mint, coral, sunshine yellow, violet), round smiling rocket, no grey-metal hazard look, nothing
sharp or scary; the home planet is a cartoon blue-green ball (no real continents or countries).

Example:
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only Moon_LandingPlaza
"""

from __future__ import annotations

import math

from mathutils import Vector

from models._critter_kit import eyes, smile, star, tube
from models.area01 import sign_text, text_cells
from models.area04 import _hash
from models.dino_area01 import boulder
from models.hub import lin, polar, ring, slab
from models.plotframe import band_outline, front_z, rect_outline
from snkit.core import CREAM, Model, WHITE
from snkit.kit import block, sign_frame
from snkit.shapes import box, cylinder, ellipsoid, extrude_outline, loft, prism, revolve, ring_tube, rot_x, rot_y, rot_z

TAU = 2 * math.pi

# ---- Moon palette (spec §2.2 "Look": moon-grey + chrome-white + candy accents) ------------------
# Lead review 2026-10-31: the first pass was lilac on lilac (ground, plots, rocks + a lilac light)
# and the candy accents did not pop. Grounds are now near-neutral light greys with a darker, bluer
# crater field around the plots; the lighting preset is neutral too (WorldClientConfig "moon").
MOON_FAR = (156, 162, 200)  # far moon floor / crater field: darker + bluer, so plots and plaza read lighter
MOON_DUST = (226, 226, 238)  # Landing Plaza dust (near-neutral light grey: lets candy accents pop)
PLOT_DUST = (236, 236, 244)  # plot ground under the lots (the lightest ground: plots stand out from the field)
CRATER_RIM = (180, 186, 216)
CRATER_FLOOR = (146, 152, 190)
CHROME = (236, 238, 248)  # plaza ring, edging, towers
CHROME_DARK = (196, 200, 222)
TILE_VIOLET = (164, 136, 240)  # plaza tiles
PATH = (128, 136, 204)  # trails, ring path, plot path (periwinkle: reads against the dust)
PATH_DARK = (106, 112, 184)
NAVY = (46, 52, 104)  # sign board, screen, engine bells
CORAL = (255, 112, 96)
MINT = (110, 226, 178)
SUN_YELLOW = (255, 220, 80)
VIOLET = (150, 104, 232)
ROCK = (168, 172, 202)  # moon rocks, ridge (cool blue-grey)
ROCK_DARK = (126, 132, 168)
WATER = (140, 206, 255)  # "star water" (Smooth, like the Valley pond)
FOAM = (220, 244, 255)
CRYSTAL_VIOLET = (196, 150, 255)
CRYSTAL_MINT = (130, 240, 214)
INK = (40, 40, 60)
LAMP = (255, 236, 160)
RINGED = (255, 176, 130)  # ringed planet (peach)
RINGED_BAND = (236, 132, 110)
PLANET_RING = (210, 190, 255)
HOME_OCEAN = (84, 156, 255)
HOME_LAND = (110, 214, 120)
CLOUD = (244, 246, 255)

# ---- World-local dimensions (MoonHubLayout.luau mirrors these; change both together) ----------
PLOT_R = 260.0  # plot origin radius (= ring path outer edge)
RING_IN = 230.0  # ring path inner radius
DUST_R = 244.0  # plaza dust disc radius (tucks under the ring path)
PLAZA_IN, PLAZA_OUT = 25.6, 88.0  # chrome landing ring
PLAZA_TOP = 0.18
TILE_TOP = 0.24
TRAIL_TOP = 0.12
RING_TOP = 0.06
CRATER_RIM_TOP, CRATER_FLOOR_TOP = 0.08, 0.03
TRAIL_HALF = 9.0
TRAIL_Z0, TRAIL_Z1 = 87.4, 236.0
MOUTH_HALF = 10.0
POOL_R = 22.4  # pool water radius; basin rim r 22..26 (top 1.6)
RIM_TOP = 1.6
WATER_TOP = 1.0
PLOT_LEN = 312.0
PLOT_HALF = 80.0
CURB_HALF = 10.0
ROAD_HALF = 8.0
RIDGE_FOOT_R = 652.0  # ridge foot (the collision ring is at r 650)
RIDGE_TOP_R = 644.0
GROUND_R = 662.0
SPAWN_YAW = 22.5  # spawn faces outward along this yaw (mirrors Nuke Town / Dino Valley)

# Rocket fountain (MoonHubLayout mirrors ROCKET_TIP / JET_LAND for its ambient particles).
ROCKET_S = 1.5  # statue scale about its feet
ROCKET_Y0 = 2.6  # fin feet on the rock island
FIN_ANGLES = (60.0, 180.0, 300.0)  # fin directions measured from the FRONT (-Z) toward +X (_fin_dir)
JET_LAND_R = 17.0  # jets land in the pool at this radius (ripple rings reach r 19.7 < POOL_R)


def _pt(r, yaw_rad, y):
    """World-local point at radius r / yaw (radians from +Z toward +X), height y."""
    x, z = polar(r, yaw_rad)
    return (x, y, z)


def _fin_dir(angle_deg):
    """Unit (x, z) of a fin at `angle_deg` measured from -Z (the statue's FRONT) toward +X."""
    a = math.radians(angle_deg)
    return (math.sin(a), -math.cos(a))


# =================================================================================================
# Landing Plaza floor
# =================================================================================================


def build_ground():
    """Far moon floor disc r 0..662 (top y = -0.4), under the plaza, the plots, the wedges and the ridge."""
    m = Model("Moon_Ground", "world-local origin (Landing Plaza centre); top y = -0.4; r <= 662", budget=600)
    ground = m.piece("Ground", MOON_FAR, material="StudsLarge")
    ring(ground, 0.0, GROUND_R, -2.0, -0.4, 72, chamfer=0.0)
    return m


def _crater_dimple(rim, floor, cx, cz, r):
    """A little crater on the dust: raised rim ring (top 0.08) round a darker floor (top 0.03).
    The floor tucks 0.05 under the rim and sits lower, so the two never share a plane (R18)."""
    ring(rim, r, r + 1.1, -0.04, CRATER_RIM_TOP, 8, chamfer=0.0, center=(cx, cz))
    ring(floor, 0.0, r + 0.05, -0.06, CRATER_FLOOR_TOP, 8, chamfer=0.0, center=(cx, cz))


def build_landing_plaza():
    """
    Landing Plaza floor: moon-dust disc (top 0), chrome landing ring r 25.6..88 (top 0.18) with
    violet tiles (0.24, inner + outer bands only: never under the rocket portal or the teleport
    pads), the welcome walk from the plaza to the title sign (yaw 22.5, top 0.12) and little craters
    on the dust between the trails (rim 0.08 / floor 0.03).
    """
    m = Model("Moon_LandingPlaza", "world-local origin; dust top 0, chrome ring r 25.6-88 top 0.18", budget=3500)
    dust = m.piece("Dust", MOON_DUST)
    plaza = m.piece("Plaza", CHROME)
    tiles = m.piece("Tiles", TILE_VIOLET)
    walk_piece = m.piece("Walk", PATH)
    rim = m.piece("CraterRim", CRATER_RIM)
    floor = m.piece("CraterFloor", CRATER_FLOOR)
    ring(dust, 0.0, DUST_R, -1.0, 0.0, 48, chamfer=0.2)
    ring(plaza, PLAZA_IN, PLAZA_OUT, -0.3, PLAZA_TOP, 72, chamfer=0.08)
    # Violet tiles: two bands of rounded squares (embedded 0.02 into the ring: no shared plane).
    for band_r, count, size in ((31.5, 18, 2.4), (83.0, 40, 2.8)):
        for k in range(count):
            a = TAU * (k + 0.5) / count
            x, _, z = _pt(band_r, a, 0.0)
            box(tiles, (x, PLAZA_TOP + 0.02, z), (size, 0.08, size), rot=rot_y(math.degrees(a) + 45.0))
    # Welcome walk: plaza edge -> title sign along the spawn axis.
    walk = rect_outline(-6.0, 6.0, PLAZA_OUT - 0.4, 122.0)
    c, s = math.cos(math.radians(SPAWN_YAW)), math.sin(math.radians(SPAWN_YAW))

    def walk_at(d):
        return [(x * c + z * s, -x * s + z * c) for x, z in walk(d)]

    slab(walk_piece, walk_at, -0.3, TRAIL_TOP, chamfer=0.04)
    # Little craters between the trails (wedge-local, mirrored in every wedge except the arrival one).
    spots = ((-18.0, 150.0, 4.0), (-30.0, 205.0, 4.6))
    for k in range(1, 8):
        beta = math.radians(22.5 + 45 * k)
        for lx, lz, r in spots:
            cx = lx * math.cos(beta) + lz * math.sin(beta)
            cz = -lx * math.sin(beta) + lz * math.cos(beta)
            _crater_dimple(rim, floor, cx, cz, r)
    return m


def build_ring_path():
    """
    45° of the periwinkle ring path r 230..260 centred on +Z (top 0.06), with a STRAIGHT mouth
    (|x| <= 10, z = 260) where the plot path starts, and chrome edge studs along the outer edge.
    """
    m = Model("Moon_RingPath", "world-local origin; arc centred on +Z, yaw +-22.5; top y = 0.06", budget=900)
    path = m.piece("Path", PATH_DARK)
    studs = m.piece("Studs", CHROME)
    half = math.radians(22.5)
    mouth_a = math.asin(MOUTH_HALF / PLOT_R)
    outer_l = [polar(PLOT_R, a) for a in lin(-half, -mouth_a, 9)]
    outer_r = [polar(PLOT_R, a) for a in lin(mouth_a, half, 9)]
    inner = [polar(RING_IN, a) for a in lin(half, -half, 18)]
    outline = outer_l + [(-MOUTH_HALF, PLOT_R), (MOUTH_HALF, PLOT_R)] + outer_r + inner
    extrude_outline(path, outline, -0.3, RING_TOP)
    for i, a in enumerate(lin(-half + 0.03, half - 0.03, 10)):
        if abs(math.sin(a) * 255) < MOUTH_HALF + 2:
            continue
        x, z = polar(256.0, a)
        cylinder(studs, (x, RING_TOP - 0.02, z), (x, RING_TOP + 0.14, z), 0.7, segments=8)
    return m


def build_trail():
    """
    Periwinkle trail along +Z from the plaza (z 87.4) to the ring path (z 236), |x| <= 9 (top 0.12),
    chrome curbs on both sides, centre dashes and plot-coloured landing lights (`Lights`, TINTED)
    along the curbs.
    """
    m = Model("Moon_Trail", "world-local origin; trail along +Z (yaw (i-1)*45); top y = 0.12; Lights tinted", budget=2500)
    path = m.piece("Path", PATH)
    curbs = m.piece("Curbs", CHROME_DARK)
    dashes = m.piece("Dashes", CHROME)
    lights = m.piece("Lights", SUN_YELLOW, tinted=True)
    slab(path, rect_outline(-TRAIL_HALF, TRAIL_HALF, TRAIL_Z0, TRAIL_Z1), -0.3, TRAIL_TOP, chamfer=0.04)
    # Curbs in 16-stud pieces with small gaps (rounded bars lying on the dust, top 0.5).
    z = TRAIL_Z0 + 3.0
    while z + 14.0 < 226.0:
        for sx in (-1, 1):
            block(curbs, (sx * (TRAIL_HALF + 0.55), 0.25, z + 7.0), (1.0, 0.5, 14.0), bevel=0.18)
        z += 16.0
    # Centre dashes (top 0.15) + landing lights on little posts outside the curbs.
    for zz in lin(TRAIL_Z0 + 8.0, TRAIL_Z1 - 12.0, 10):
        block(dashes, (0.0, TRAIL_TOP + 0.015, zz), (1.2, 0.06, 4.0), bevel=0.02)
    for zz in lin(TRAIL_Z0 + 10.0, 220.0, 6):
        for sx in (-1, 1):
            x = sx * (TRAIL_HALF + 2.2)
            cylinder(curbs, (x, 0.0, zz), (x, 0.9, zz), 0.32, segments=6)
            ellipsoid(lights, (x, 1.15, zz), (0.42, 0.42, 0.42), rings=3, segments=6)
    return m


# =================================================================================================
# Landing Plaza fixtures
# =================================================================================================


def _rocket_statue(m, scale, y0, with_face=True):
    """
    The friendly toy rocket of the fountain (authored at unit size, scaled about its feet): white
    fuselage with violet bands, sunshine nose + tip ball, three coral fins, big eyes + a smile on the
    front (-Z), a navy engine bell. Returns the fin-tip nozzle points (world, for the water jets).
    """
    body = m.piece("Body", CHROME)
    # Sunshine nose + coral fins (the portal rocket, Hub_MoonRocket, is coral-nosed with mint fins:
    # the two rockets on the plaza read as different toys).
    nose = m.piece("Nose", SUN_YELLOW)
    band = m.piece("Band", VIOLET)
    fins = m.piece("Fins", CORAL)
    dark = m.piece("Dark", NAVY)
    ink = m.piece("Ink", INK, material="Smooth")
    shine = m.piece("Shine", WHITE, material="Smooth")
    cheeks = m.piece("Cheeks", (255, 160, 170))

    def P(x, y, z):
        return (x * scale, y0 + y * scale, z * scale)

    def R(r):
        return tuple(v * scale for v in r) if isinstance(r, tuple) else r * scale

    rc = P(0.0, 0.0, 0.0)
    br = R(4.2)
    revolve(body, [(0.0, P(0, 4.4, 0)[1]), (R(3.4), P(0, 4.4, 0)[1]), (br, P(0, 6.4, 0)[1]), (br, P(0, 19.0, 0)[1]), (0.0, P(0, 19.0, 0)[1])], center=(rc[0], 0.0, rc[2]), segments=24)
    nose_prof = [(0.0, P(0, 18.98, 0)[1]), (br - 0.02, P(0, 18.98, 0)[1]), (R(3.9), P(0, 21.6, 0)[1]), (R(3.1), P(0, 24.2, 0)[1]), (R(1.9), P(0, 26.4, 0)[1]), (R(0.8), P(0, 27.8, 0)[1]), (0.0, P(0, 28.4, 0)[1])]
    revolve(nose, nose_prof, center=(rc[0], 0.0, rc[2]), segments=24)
    ellipsoid(nose, P(0.0, 29.0, 0.0), R((0.8, 0.8, 0.8)), rings=5, segments=10)
    for y in (8.2, 17.6):
        y0b, y1b = P(0, y - 0.55, 0)[1], P(0, y + 0.55, 0)[1]
        revolve(band, [(br + 0.12, y0b), (br + 0.12, y1b), (br - 0.2, y1b), (br - 0.2, y0b)], center=(rc[0], 0.0, rc[2]), segments=24, closed=True)
    revolve(dark, [(R(1.4), P(0, 4.5, 0)[1]), (R(1.9), P(0, 3.4, 0)[1]), (R(2.6), P(0, 2.2, 0)[1]), (R(2.2), P(0, 2.2, 0)[1]), (R(1.1), P(0, 3.4, 0)[1]), (R(0.9), P(0, 4.5, 0)[1])], center=(rc[0], 0.0, rc[2]), segments=16, closed=True)
    nozzles = []
    for angle in FIN_ANGLES:
        ux, uz = _fin_dir(angle)
        outline = [(3.8, 12.0), (3.8, 4.8), (7.6, 0.0), (7.6, 2.8), (6.0, 8.6)]
        pts = [P(ux * d, y, uz * d) for d, y in outline]
        prism(fins, pts, (uz, 0.0, -ux), R(0.8))
        # A chrome nozzle cap at the fin tip (the water jet leaves it).
        tip = P(ux * 7.6, 2.0, uz * 7.6)
        ellipsoid(body, tip, R((0.6, 0.6, 0.6)), rings=4, segments=8)
        nozzles.append((tip, (ux, uz)))
    if with_face:
        head_c, head_r = P(0.0, 13.6, 0.0), R((4.2, 5.2, 4.2))
        # Eye / smile sizes are absolute studs (the statue is ~44 tall: big readable toy eyes).
        eyes(ink, shine, head_c, head_r, yaw=24.0, pitch=10.0, size=1.15, tall=1.3, sink=0.3)
        smile(ink, head_c, head_r, pitch=-14.0, width=24.0, depth=7.0, thickness=0.3)
        for sx in (-1, 1):
            a = math.radians(sx * 46.0)
            cx = math.sin(a) * br * 1.0
            cz = -math.cos(a) * br * 1.0
            ellipsoid(cheeks, (cx, P(0, 12.4, 0)[1], cz), R((0.75, 0.5, 0.25)), rings=3, segments=6)
    return nozzles


def build_rocket_fountain():
    """
    Hero: a friendly smiling toy rocket stands on a moon-rock island in the middle of a chrome-rimmed
    pool of sparkly "star water"; three water jets arc from its fin tips into the pool (each landing
    ring is `Ripple`, which bobs via WorldFx) and little yellow stars (`Sparkles`) float on the
    water. Faces -Z.
    """
    m = Model(
        "Moon_RocketFountain",
        "pool centre on the ground; rim r 22-26 top 1.6, water top 1.0; rocket faces -Z; tip ~ (0, 46.6, 0)",
        budget=6000,
    )
    rim = m.piece("Rim", CHROME)
    rim_band = m.piece("RimBand", VIOLET)
    water = m.piece("Water", WATER, material="Smooth")
    ripple = m.piece("Ripple", FOAM, material="Smooth")
    rocks = m.piece("Rocks", ROCK_DARK)
    sparkles = m.piece("Sparkles", SUN_YELLOW, material="StudsSmall")
    ring(rim, 22.0, 26.0, -0.6, RIM_TOP, 56, chamfer=0.3)
    ring(rim_band, 25.98, 26.3, 0.5, 1.1, 56, chamfer=0.0)
    ring(water, 0.0, POOL_R, 0.2, WATER_TOP, 56, chamfer=0.0)
    # Moon-rock island under the rocket.
    for i, (x, z, rx, ry) in enumerate(((0.0, 0.0, 7.4, 2.8), (-5.0, 5.0, 3.4, 2.0), (5.2, 4.4, 3.0, 1.8), (1.0, -6.0, 3.0, 1.6))):
        boulder(rocks, (x, 1.0, z), (rx, ry, rx * 0.85), seed=140 + i, rings=4, segments=8)
    nozzles = _rocket_statue(m, ROCKET_S, ROCKET_Y0)
    # Water jets: from each fin-tip nozzle up and out, landing in the pool at JET_LAND_R.
    for (tip, (ux, uz)) in nozzles:
        start = Vector(tip)
        land = Vector((ux * JET_LAND_R, WATER_TOP, uz * JET_LAND_R))
        ctrl = Vector((ux * 13.0, tip[1] + 7.0, uz * 13.0))
        arc = []
        for t in lin(0.0, 1.0, 8):
            a = start.lerp(ctrl, t)
            b = ctrl.lerp(land, t)
            arc.append(tuple(a.lerp(b, t)))
        tube(water, arc, 0.45, sides=7, radii=[0.4, 0.46, 0.5, 0.52, 0.52, 0.5, 0.48, 0.46, 0.44])
        ring(ripple, 1.0, 1.6, WATER_TOP - 0.05, WATER_TOP + 0.12, 14, chamfer=0.0, center=(land.x, land.z))
        ring(ripple, 2.0, 2.4, WATER_TOP - 0.05, WATER_TOP + 0.08, 14, chamfer=0.0, center=(land.x, land.z))
    # Floating stars on the water, clear of the jets' landing rings.
    for k in range(9):
        a = TAU * k / 9 + 0.2
        r = 11.5 + 6.0 * _hash(k, 1.7)
        x, z = polar(r, a)
        if min(math.hypot(x - ux * JET_LAND_R, z - uz * JET_LAND_R) for _, (ux, uz) in nozzles) < 4.0:
            continue
        star(sparkles, (x, WATER_TOP + 0.12, z), 0.9, 0.2, normal=(0, 1, 0), up=(0, 0, -1))
    return m


def _letters_board(m, lines, center, width, height, depth, cell):
    """Chrome-framed navy board with sunshine letters on BOTH faces (owner R17); returns nothing."""
    cx, cy, cz = center
    panel = m.piece("Panel", NAVY)
    frame = m.piece("Frame", CHROME)
    letters = m.piece("Letters", SUN_YELLOW, material="Smooth")
    block(panel, (cx, cy, cz), (width - 0.4, height - 0.4, depth), bevel=0.15)
    for sy in (-1, 1):
        block(frame, (cx, cy + sy * height / 2, cz), (width + 1.6, 1.0, depth + 0.5), bevel=0.3)
    for sx in (-1, 1):
        block(frame, (cx + sx * width / 2, cy, cz), (1.0, height - 0.8, depth + 0.5), bevel=0.3)
    sign_text(letters, lines, (cx, cy, cz), cell, 0.32, depth / 2)


def build_title_sign():
    """
    "MOON BASE" welcome sign (the first thing the spawn faces): two chrome antenna towers with coral
    bands, a navy board with the name in sunshine letters on both faces, a ringed toy planet crest
    and small warm Neon beacons on the tower tops (R19).
    """
    m = Model("Moon_TitleSign", "ground centre between the posts; letters on both faces; front -Z", budget=6000)
    towers = m.piece("Towers", CHROME)
    bands = m.piece("Bands", CORAL)
    feet = m.piece("Feet", ROCK_DARK)
    crest = m.piece("Crest", (255, 176, 130))
    crest_ring = m.piece("CrestRing", PLANET_RING)
    lines = ["MOON", "BASE"]
    cell = 0.95
    widest = max(text_cells(line) for line in lines)
    board_w = widest * cell + 3.2
    board_h = (7 * 2 + 2) * cell + 2.4
    post_x = board_w / 2 + 1.6
    post_h = 12.0
    top_y = post_h + board_h * 0.5 + 3.0
    for sx in (-1, 1):
        x = sx * post_x
        block(feet, (x, 1.0, 0.0), (5.4, 2.0, 5.4), bevel=0.6, segments=2)
        cylinder(towers, (x, 1.9, 0.0), (x, top_y, 0.0), 1.9, segments=12)
        for y in (5.0, 9.5, top_y - 2.2):
            cylinder(bands, (x, y - 0.4, 0.0), (x, y + 0.4, 0.0), 2.05, segments=12)
        cylinder(towers, (x, top_y, 0.0), (x, top_y + 2.4, 0.0), 0.4, segments=6)
        side = "L" if sx < 0 else "R"
        beacon = m.piece(f"Beacon{side}", LAMP, material="Neon")
        ellipsoid(beacon, (x, top_y + 3.0, 0.0), (0.65, 0.65, 0.65), rings=4, segments=8)
    board_y = post_h + board_h / 2
    _letters_board(m, lines, (0.0, board_y, 0.0), board_w, board_h, 1.2, cell)
    # Crest: a little ringed toy planet on a stub above the board.
    top = board_y + board_h / 2 + 0.5
    cylinder(towers, (0.0, top - 0.2, 0.0), (0.0, top + 1.4, 0.0), 0.5, segments=8)
    ellipsoid(crest, (0.0, top + 3.6, 0.0), (2.4, 2.4, 2.4), rings=6, segments=12)
    ring_tube(crest_ring, (0.0, top + 3.6, 0.0), 3.6, 1.2, 0.25, segments=20, axis="Y")
    m.title_info = {"post_x": post_x, "board_y": board_y, "board_h": board_h, "board_w": board_w}
    return m


def build_teleport_pad():
    """
    Plot teleport pad (plaza ring r 62): chrome launch disc with a plot-coloured glowing-top ring
    (`Accent`, TINTED), chevrons pointing to the plot (+Z), and behind it two chrome poles carrying
    the cream `Label` (SurfaceGui "PLOT N + owner"). Same anchor numbers as Hub_TeleportPad (Label
    centre (0, 7.4, 6.12), board top 9.0) so the digit and systems reuse them.
    UNUSED since owner R134 (2026-11-01): no hub places teleport pads any more; the builder and the
    uploaded mesh are kept (MeshAssets) only so the asset stays reproducible.
    """
    m = Model(
        "Moon_TeleportPad",
        "ground centre; pad top y = 1.0; chevrons +Z (toward the plot); Label front face z = 5.97 faces -Z; Accent tinted",
        budget=1500,
    )
    base = m.piece("Base", CHROME)
    accent = m.piece("Accent", SUN_YELLOW, tinted=True)
    top = m.piece("Top", NAVY)
    poles = m.piece("Poles", CHROME_DARK)
    label = m.piece("Label", CREAM)
    ring(base, 0.0, 5.4, 0.0, 0.5, 20, chamfer=0.15)
    ring(top, 0.0, 4.4, 0.5, 0.85, 20, chamfer=0.1)
    ring(accent, 4.4, 5.3, 0.5, 1.0, 20, chamfer=0.1)
    # Three chevrons on the pad top pointing toward the plot (+Z).
    for zc in (-2.2, 0.0, 2.2):
        for sx in (-1, 1):
            box(accent, (sx * 0.85, 0.9, zc), (2.0, 0.1, 0.55), rot=rot_y(sx * 40.0))
    # Signpost: chrome poles with tinted bands, tinted frame round the Label (board top y 9.0).
    for x in (-4.0, 4.0):
        block(base, (x, 0.3, 6.6), (1.4, 0.6, 1.4), bevel=0.12)
        cylinder(poles, (x, 0.6, 6.6), (x, 9.6, 6.6), 0.42, segments=8)
        ellipsoid(accent, (x, 9.85, 6.6), (0.5, 0.5, 0.5), rings=3, segments=8)
        for y in (3.0, 6.0):
            cylinder(accent, (x, y - 0.12, 6.6), (x, y + 0.12, 6.6), 0.5, segments=8)
    block(accent, (0.0, 7.4, 6.6), (8.6, 3.2, 0.6), bevel=0.12)
    block(label, (0.0, 7.4, 6.12), (7.3, 2.6, 0.3), bevel=0.05)
    return m


def build_egg_stand():
    """
    Hover pedestal for a Moon egg: lilac plinth, a chrome crater cup (cradle top y ~4.4, the egg's
    pivot at y 4.0), chrome posts holding the framed `Sign` behind the egg (front face z = 2.72) and
    a tinted star crest. Same anchor numbers as Hub_EggStand.
    """
    m = Model(
        "Moon_EggStand",
        "ground centre; egg pivot at (0, 4.0, 0); Sign front face (z = 2.72) faces -Z; Accent tinted",
        budget=2500,
    )
    base = m.piece("Base", ROCK)
    cup = m.piece("Cup", CHROME)
    accent = m.piece("Accent", VIOLET, tinted=True)
    frame = m.piece("Frame", CHROME_DARK)
    sign = m.piece("Sign", CREAM)
    block(base, (0.0, 0.4, 0.0), (8.4, 0.8, 8.4), bevel=0.3, segments=2)
    ring(base, 0.0, 2.4, 0.8, 3.2, 16, chamfer=0.2)
    # Crater cup: a chrome bowl round the cradle (rim y 4.4), the egg sits at y 4.0.
    revolve(cup, [(2.3, 3.2), (2.9, 3.4), (3.0, 4.4), (2.6, 4.4), (2.2, 3.7)], segments=18, closed=True)
    ring(accent, 2.45, 3.05, 3.0, 3.4, 18, chamfer=0.1)
    # Poles run past the frame (top 13.6): their caps never share the sign panel's top plane (R18).
    for x in (-4.6, 4.6):
        cylinder(frame, (x, 0.8, 2.9), (x, 13.6, 2.9), 0.45, segments=8)
        ellipsoid(accent, (x, 13.85, 2.9), (0.55, 0.55, 0.55), rings=3, segments=8)
    sign_frame(frame, sign, (0.0, 11.4, 2.9), (9.6, 3.6), border=0.4, depth=0.5)
    star(accent, (0.0, 14.6, 2.9), 1.3, 0.4)
    return m


def build_leaderboard():
    """
    Chrome monitor leaderboard: navy `Screen` (12.8 x 17.8, front face z = -0.25 at y 12.9) inside a
    tinted `Frame`, two mint rocket-fin feet, a chrome back slab and a golden star trophy on top. Same
    Screen numbers as Hub_Leaderboard (the leaderboard service sizes its SurfaceGui from them).
    """
    m = Model("Moon_Leaderboard", "ground centre; Screen front face (12.8 x 17.8) at z = -0.25 faces -Z; Frame tinted", budget=2500)
    base = m.piece("Base", CHROME)
    dark = m.piece("Dark", ROCK_DARK)
    feet = m.piece("Feet", MINT)
    frame = m.piece("Frame", VIOLET, tinted=True)
    screen = m.piece("Screen", NAVY)
    trophy = m.piece("Trophy", SUN_YELLOW)
    block(dark, (0.0, 0.6, 0.2), (17.0, 1.2, 4.2), bevel=0.4, segments=2)
    for sx in (-1, 1):
        prism(feet, [(sx * 5.4, 1.2, 0.4), (sx * 8.0, 1.2, 0.4), (sx * 6.8, 5.6, 0.4), (sx * 5.4, 4.6, 0.4)], (0, 0, 1), 1.0)
    cy = 12.9
    # Back slab behind the screen: its front face (z = -0.15) sits 0.1 behind the Screen's (R18).
    block(base, (0.0, cy, 0.55), (15.6, 20.6, 1.4), bevel=0.5, segments=2)
    block(screen, (0.0, cy, 0.0), (12.8, 17.8, 0.5), bevel=0.05)
    for y in (cy - 9.3, cy + 9.3):
        block(frame, (0.0, y, -0.05), (14.4, 0.8, 0.7), bevel=0.12)
    for x in (-6.8, 6.8):
        block(frame, (x, cy, -0.05), (0.8, 19.4, 0.7), bevel=0.12)
    # Trophy: a golden star on a little cup.
    revolve(trophy, [(0.0, 0.0), (1.2, 0.0), (1.2, 0.3), (0.4, 0.6), (0.4, 1.2), (1.2, 1.6), (0.0, 1.6)], center=(0.0, cy + 10.4, 0.45), segments=12)
    star(trophy, (0.0, cy + 14.0, 0.45), 2.0, 0.7)
    return m


# =================================================================================================
# Plot frame (plot-local)
# =================================================================================================


def build_plot_ground():
    """Moon-dust plates either side of the path corridor (|x| <= 10), top y = 0, curved front, back z 312."""
    m = Model("Moon_PlotGround", "plot-local origin (entrance centre on the ring path); top y = 0", budget=600)
    ground = m.piece("Ground", PLOT_DUST)
    slab(ground, band_outline(-PLOT_HALF, -CURB_HALF, PLOT_LEN), -1.0, 0.0, chamfer=0.3)
    slab(ground, band_outline(CURB_HALF, PLOT_HALF, PLOT_LEN), -1.0, 0.0, chamfer=0.3)
    return m


def build_path():
    """
    The plot's periwinkle path: |x| <= 8 (top 0.06, z 0..312.6), chrome edging 8 <= |x| <= 10 (top
    0.4, from z -0.1 over the ring path mouth), landing-light tiles down the middle (top 0.09).
    """
    m = Model("Moon_Path", "plot-local origin; path |x| <= 8 top 0.06; edging to |x| = 10 (top 0.4)", budget=2500)
    path = m.piece("Path", PATH)
    edging = m.piece("Edging", CHROME_DARK)
    tiles = m.piece("Tiles", CHROME)
    slab(path, rect_outline(-ROAD_HALF, ROAD_HALF, 0.0, PLOT_LEN + 0.6), -1.0, RING_TOP, chamfer=0.04)
    for x0, x1 in ((-CURB_HALF, -ROAD_HALF), (ROAD_HALF, CURB_HALF)):
        slab(edging, rect_outline(x0, x1, -0.1, PLOT_LEN), -1.0, 0.4, chamfer=0.12)
    z = 6.0
    while z < PLOT_LEN - 4.0:
        block(tiles, (0.0, RING_TOP + 0.03, z), (1.4, 0.1, 4.2), bevel=0.03)
        z += 8.0
    return m


def build_crater_rim():
    """
    Rocky crater rim round the sides and back, just OUTSIDE the plot footprint (x = +-[80.2, 82.6],
    z = [312.2, 314.6]) on a chrome curb, with plot-coloured landing lights (`Lights`, TINTED).
    """
    m = Model("Moon_CraterRim", "plot-local origin; rim x = +-[80.2, 82.6], z = [312.2, 314.6], top y ~ 2.6", budget=2500)
    rim = m.piece("Rim", ROCK)
    curb = m.piece("Curb", CHROME_DARK)
    lights = m.piece("Lights", SUN_YELLOW, tinted=True)
    z0 = front_z(PLOT_HALF) + 1.2
    side_len = PLOT_LEN + 2.4 - z0
    for x in (-81.4, 81.4):
        block(curb, (x, 0.35, z0 + side_len / 2), (2.6, 0.9, side_len), bevel=0.2)
        block(rim, (x, 1.6, z0 + side_len / 2), (2.4, 2.0, side_len - 0.4), bevel=0.7, segments=2)
    block(curb, (0.0, 0.35, 313.4), (165.4, 0.9, 2.6), bevel=0.2)
    block(rim, (0.0, 1.6, 313.4), (165.0, 2.0, 2.4), bevel=0.7, segments=2)
    spots = [(x, z) for x in (-81.4, 81.4) for z in lin(z0 + 3.0, 310.0, 30)]
    spots += [(x, 313.4) for x in lin(-76.0, 76.0, 16)]
    for i, (x, z) in enumerate(spots):
        box(lights, (x + (_hash(i, 1.0) - 0.5) * 0.6, 2.62, z), (0.8, 0.3, 0.8))
    return m


def build_entrance_arch():
    """
    Moon plot entrance arch: chrome towers at x = +-13 (5 x 5 footprint like Plot_EntranceArch) with
    tinted bands (`Accent`), a twin girder beam carrying the cream `OwnerSign` panels on both faces,
    and a little toy rocket on top with a small warm Neon porthole.
    """
    m = Model(
        "Moon_EntranceArch",
        "plot-local (0, 0, 4) on the ground; OwnerSign panels: Front face z = -2.0 (toward the plaza), Back z = +2.0",
        budget=3500,
    )
    tower = m.piece("Tower", CHROME)
    foot = m.piece("Foot", ROCK_DARK)
    beam = m.piece("Beam", CHROME_DARK)
    accent = m.piece("Accent", SUN_YELLOW, tinted=True)
    sign = m.piece("OwnerSign", CREAM)
    rocket = m.piece("Rocket", WHITE)
    nose = m.piece("Nose", CORAL)
    fins = m.piece("Fins", MINT)
    window = m.piece("Window", LAMP, material="Neon")
    for sx in (-1, 1):
        x = sx * 13.0
        block(foot, (x, 1.0, 0.0), (5.0, 2.0, 5.0), bevel=0.5, segments=2)
        block(tower, (x, 9.2, 0.0), (4.2, 14.4, 4.2), bevel=0.8, segments=2)
        for yb in (4.0, 12.4):
            block(accent, (x, yb, 0.0), (4.7, 0.7, 4.7), bevel=0.15)
        ellipsoid(accent, (x, 16.9, 0.0), (1.2, 1.2, 1.2), rings=4, segments=8)
    # Twin girder beam (x +-15.6) with the owner sign boards on both faces.
    for z in (-0.9, 0.9):
        block(beam, (0.0, 17.3, z), (31.2, 2.3, 1.2), bevel=0.3)
    block(beam, (0.0, 19.3, 0.0), (30.0, 1.4, 1.6), bevel=0.3)
    for z in (-1.85, 1.85):
        block(sign, (0.0, 17.3, z), (22.0, 3.6, 0.3), bevel=0.06)
    # Toy rocket on top (the plot's crest).
    revolve(rocket, [(0.0, 20.0), (0.9, 20.0), (1.2, 20.6), (1.2, 23.4), (0.0, 23.4)], segments=14)
    revolve(nose, [(0.0, 23.38), (1.2, 23.38), (0.9, 24.6), (0.4, 25.5), (0.0, 25.8)], segments=14)
    for angle in (0.0, 120.0, 240.0):
        a = math.radians(angle)
        ux, uz = math.sin(a), math.cos(a)
        prism(fins, [(ux * 1.0, 22.0, uz * 1.0), (ux * 1.0, 20.2, uz * 1.0), (ux * 2.1, 20.0, uz * 2.1), (ux * 2.1, 20.8, uz * 2.1)], (uz, 0.0, -ux), 0.3)
    cylinder(window, (0.0, 22.3, -1.12), (0.0, 22.3, -1.3), 0.45, segments=10)
    return m


def build_locked_slot():
    """
    'Coming soon' placeholder for a locked Moon slot: a chrome space-barrier fence across the slot
    front, the framed board (`Sign`, the SurfaceGui face at z = 4.19 like Plot_LockedSlot) and a landed
    supply capsule with a parachute heap, waiting to open.
    """
    m = Model(
        "Moon_LockedSlot",
        "SLOT-local origin (road-side edge midpoint, +Z away from the road); Sign front z = 4.19 faces the road",
        budget=2000,
    )
    poles = m.piece("Poles", CHROME)
    rails = m.piece("Rails", CORAL)
    sign = m.piece("Sign", CREAM)
    capsule = m.piece("Capsule", CHROME)
    stripe = m.piece("Stripe", VIOLET)
    chute = m.piece("Chute", MINT)
    xs = lin(-48.0, 48.0, 8)
    for x in xs:
        cylinder(poles, (x, 0.0, 3.0), (x, 4.2, 3.0), 0.42, segments=6)
        ellipsoid(rails, (x, 4.35, 3.0), (0.5, 0.4, 0.5), rings=3, segments=6)
    for y in (1.6, 3.2):
        for k in range(8):
            cylinder(rails, (xs[k] + 0.3, y, 2.6), (xs[k + 1] - 0.3, y, 2.6), 0.24, segments=5)
    # "COMING SOON" board on legs (same panel numbers as Plot_LockedSlot).
    sign_frame(rails, sign, (0.0, 9.2, 4.4), (14.0, 5.0), border=0.5, depth=0.6, posts=0.7, post_piece=poles)
    # Landed supply capsule (a rounded pod) + a soft parachute heap beside it.
    revolve(capsule, [(0.0, 0.0), (3.6, 0.0), (4.2, 1.2), (4.2, 4.2), (3.0, 6.6), (1.4, 7.6), (0.0, 7.8)], center=(-20.0, 0.0, 28.0), segments=16)
    revolve(stripe, [(4.3, 2.2), (4.3, 3.0), (4.0, 3.0), (4.0, 2.2)], center=(-20.0, 0.0, 28.0), segments=16, closed=True)
    ellipsoid(chute, (-12.0, 0.6, 31.0), (4.0, 1.4, 3.0), rings=4, segments=10)
    return m


# =================================================================================================
# Scenery
# =================================================================================================


def build_crater():
    """Big crater (~34 across): a raised rocky rim (top ~2.6) round a darker sunken floor, a few rocks."""
    m = Model("Moon_Crater", "ground centre; rim r 12-17, top y ~ 2.6; floor r 12 at y 0.2", budget=1200)
    rim = m.piece("Rim", CRATER_RIM)
    floor = m.piece("Floor", CRATER_FLOOR)
    rocks = m.piece("Rocks", ROCK_DARK)
    revolve(rim, [(11.6, 0.0), (17.0, 0.0), (15.0, 1.8), (13.4, 2.6), (12.2, 2.2), (11.6, 0.6)], segments=28, closed=True)
    ring(floor, 0.0, 11.8, -0.2, 0.2, 28, chamfer=0.0)
    for k in range(4):
        a = TAU * k / 4 + 0.6
        x, z = polar(5.0 + 3.0 * _hash(k, 2.2), a)
        boulder(rocks, (x, 0.5, z), (1.2, 0.9, 1.0), seed=150 + k)
    return m


def build_rock():
    """Moon rock cluster (one big + two small lumpy rocks), ~5 tall."""
    m = Model("Moon_Rock", "ground centre; ~9 x 5 x 7", budget=600)
    rock = m.piece("Rock", ROCK)
    dark = m.piece("RockDark", ROCK_DARK)
    boulder(rock, (0.0, 1.9, 0.0), (3.4, 3.0, 2.9), seed=171, rings=5, segments=9)
    boulder(dark, (3.6, 0.9, 1.2), (1.6, 1.2, 1.5), seed=172)
    boulder(dark, (-3.2, 0.7, -1.0), (1.3, 1.0, 1.2), seed=173)
    return m


def _crystal(piece, base, height, radius, tilt_deg, yaw_deg):
    """One hexagonal crystal (prism + pointed cap) leaning `tilt_deg` toward yaw `yaw_deg`."""
    a = math.radians(yaw_deg)
    t = math.radians(tilt_deg)
    axis = Vector((math.sin(a) * math.sin(t), math.cos(t), math.cos(a) * math.sin(t)))
    b = Vector(base)
    top = b + axis * height
    tip = b + axis * (height + radius * 1.6)
    cylinder(piece, tuple(b), tuple(top), radius, segments=6)
    cylinder(piece, tuple(top), tuple(tip), radius, segments=6, radius_b=0.02)


def build_crystal_cluster():
    """Crystal cluster on a moon rock: violet + mint hexagonal crystals (~7 tall), softly glowing via WorldFx."""
    m = Model("Moon_CrystalCluster", "ground centre; ~8 x 7 x 7", budget=900)
    rock = m.piece("Rock", ROCK_DARK)
    violet = m.piece("Crystal", CRYSTAL_VIOLET, material="StudsSmall")
    mint = m.piece("CrystalMint", CRYSTAL_MINT, material="StudsSmall")
    boulder(rock, (0.0, 0.6, 0.0), (3.4, 1.4, 3.0), seed=181)
    for i, (x, z, h, r, tilt, yaw) in enumerate(
        ((0.0, 0.0, 4.6, 0.9, 6, 0), (1.8, 0.6, 3.2, 0.7, 24, 80), (-1.6, 0.8, 2.8, 0.6, 26, 280), (0.4, -1.6, 2.4, 0.55, 28, 180), (-0.6, 1.8, 2.0, 0.5, 30, 340))
    ):
        _crystal(violet if i % 2 == 0 else mint, (x, 1.2, z), h, r, tilt, yaw)
    return m


def build_antenna():
    """
    Comms antenna: a tripod of chrome legs, a mast with coral bands, a dish (`Dish`: WorldFx sweeps
    it slowly about the mast axis; the dish piece is centred on the axis so it turns in place) and a
    small warm Neon `Bulb` on the tip (soft blink light via WorldFx).
    """
    m = Model("Moon_Antenna", "ground centre; mast top y ~ 15; dish centred on the mast axis", budget=900)
    legs = m.piece("Legs", CHROME_DARK)
    mast = m.piece("Mast", CHROME)
    bands = m.piece("Bands", CORAL)
    dish = m.piece("Dish", WHITE)
    bulb = m.piece("Bulb", LAMP, material="Neon")
    for k in range(3):
        a = TAU * k / 3
        x, z = polar(3.2, a)
        cylinder(legs, (x, 0.0, z), (0.0, 6.0, 0.0), 0.3, segments=6)
        block(legs, (x, 0.2, z), (1.2, 0.4, 1.2), bevel=0.1)
    cylinder(mast, (0.0, 0.0, 0.0), (0.0, 12.0, 0.0), 0.5, segments=8)
    for y in (4.0, 8.0):
        cylinder(bands, (0.0, y - 0.3, 0.0), (0.0, y + 0.3, 0.0), 0.65, segments=8)
    # Dish: a shallow bowl tilted up-forward, centred on the axis (y 12.8), with its feed arm.
    revolve(dish, [(0.0, 0.0), (1.4, 0.1), (2.6, 0.5), (3.0, 0.9), (2.8, 0.95), (1.2, 0.35), (0.0, 0.25)], center=(0.0, 12.0, 0.0), segments=14, rot=rot_x(-35.0))
    cylinder(dish, (0.0, 12.3, 0.0), (0.0, 13.9, -1.1), 0.18, segments=5)
    # Counterweight behind the dish (part of the Dish piece): it makes the piece's box symmetric
    # front / back, so the box centre sits on the mast axis and WorldFx turns the dish in place.
    box(dish, (0.0, 12.4, 2.75), (0.9, 0.9, 0.3))
    cylinder(mast, (0.0, 12.0, 0.0), (0.0, 15.2, 0.0), 0.22, segments=6)
    ellipsoid(bulb, (0.0, 15.6, 0.0), (0.5, 0.5, 0.5), rings=4, segments=8)
    return m


def build_boundary_ridge():
    """
    45° of the crater-wall boundary ridge (world-local origin, centred on +Z): an irregular rock wall
    whose foot is at r 652 (just outside the r 650 collision ring) leaning in to r 644 at the top
    (y 34-46), with a darker strata band, a pale dusty crest, a back slope to r 700 and crystal
    clusters bulging out ABOVE head height. Persistent (the crater rim round the base).
    """
    m = Model("Moon_BoundaryRidge", "world-local origin; 45° arc centred on +Z; foot r 652, top r 644 (y ~ 40)", budget=3000)
    rock = m.piece("Rock", ROCK)
    dark = m.piece("RockDark", ROCK_DARK)
    crest_piece = m.piece("Crest", MOON_DUST)
    crystals = m.piece("CrystalRidge", CRYSTAL_VIOLET, material="StudsSmall")
    half = math.radians(22.5)
    steps = 14
    sections = []
    tops = []
    for i in range(steps + 1):
        a = -half + 2 * half * i / steps
        h = 34.0 + 12.0 * _hash(i % steps, 4.3)
        bulge = 3.0 * (_hash(i % steps, 6.1) - 0.5)
        prof = [
            (RIDGE_FOOT_R, -1.0),
            (RIDGE_FOOT_R - 2.0 + bulge, h * 0.35),
            (RIDGE_TOP_R + bulge, h * 0.8),
            (RIDGE_TOP_R + 2.0, h),
            (RIDGE_TOP_R + 18.0, h + 2.0),
            (700.0, h * 0.6),
            (700.0, -1.0),
        ]
        sections.append([_pt(r, a, y) for r, y in prof])
        tops.append((a, h))
    loft(rock, sections)
    strata = []
    crest = []
    for a, h in tops:
        strata.append([_pt(r, a, y) for r, y in ((RIDGE_FOOT_R - 2.6, h * 0.42), (RIDGE_FOOT_R - 2.8, h * 0.5), (RIDGE_FOOT_R + 1.0, h * 0.5), (RIDGE_FOOT_R + 1.0, h * 0.42))])
        crest.append([_pt(r, a, y) for r, y in ((RIDGE_TOP_R + 1.4, h - 0.2), (RIDGE_TOP_R + 1.6, h + 1.2), (RIDGE_TOP_R + 16.0, h + 3.2), (RIDGE_TOP_R + 16.0, h + 1.4))])
    # Open ribbons (no end caps): a cap would lie on the rock's end-cap plane and z-fight (R18).
    loft(dark, strata, cap_start=False, cap_end=False)
    loft(crest_piece, crest, cap_start=False, cap_end=False)
    # Rock bulges + crystal tufts ABOVE head height (y >= 14): nothing pokes inside r 650 at foot level.
    for k in range(5):
        a = -half + 2 * half * (k + 0.5) / 5 + 0.03 * (_hash(k, 6.2) - 0.5)
        y = 16.0 + 10.0 * _hash(k, 7.4)
        x, _, z = _pt(RIDGE_FOOT_R - 2.5, a, 0.0)
        boulder(dark if k % 2 == 0 else rock, (x, y, z), (8.0, 6.0, 4.6), seed=230 + k, rings=4, segments=8)
    for k, frac in enumerate((0.3, 0.72)):
        a = -half + 2 * half * frac
        h = 34.0 + 12.0 * _hash(int(frac * steps), 4.3)
        x, _, z = _pt(RIDGE_TOP_R + 9.0, a, 0.0)
        for j, (dx, dz, hh, tilt, yaw) in enumerate(((0.0, 0.0, 6.0, 8, 0), (1.6, 0.8, 4.0, 26, 70), (-1.4, 1.0, 3.6, 28, 290))):
            _crystal(crystals, (x + dx, h + 1.0, z + dz), hh, 1.0 - 0.15 * j, tilt, yaw)
    return m


def build_planet_backdrop():
    """
    Far backdrop (r 765, high in the sky, low-poly, Persistent): a big peach ringed planet (with darker bands and a
    tilted lilac ring) high in the navy sky, and a smaller cartoon blue-green home planet (round
    green blobs + a white cloud band; no real continents) beside it. Pivot = ground centre under
    them; front -Z faces the plaza.
    """
    m = Model("Moon_PlanetBackdrop", "ground centre; ringed planet centre (0, 260, 0) r 80; home planet (190, 180, 30) r 44 (+X = the viewer's LEFT); front -Z", budget=2500)
    ringed = m.piece("Ringed", RINGED, material="StudsLarge")
    bands = m.piece("RingedBands", RINGED_BAND, material="StudsLarge")
    pring = m.piece("PlanetRing", PLANET_RING, material="StudsLarge")
    ocean = m.piece("Ocean", HOME_OCEAN, material="StudsLarge")
    land = m.piece("Land", HOME_LAND, material="StudsLarge")
    cloud = m.piece("Cloud", CLOUD, material="StudsLarge")
    pc = (0.0, 260.0, 0.0)
    ellipsoid(ringed, pc, (80.0, 80.0, 80.0), rings=12, segments=20)
    # Two darker bands just proud of the surface (ring sections of a revolve, tilted with the planet).
    tilt = rot_z(-18.0)
    for y0, y1 in ((-30.0, -18.0), (14.0, 24.0)):
        prof = []
        for y in (y0, y1):
            r = math.sqrt(max(80.0 * 80.0 - y * y, 1.0)) + 0.8
            prof.append((r, y))
        revolve(bands, [prof[0], prof[1], (prof[1][0] - 2.0, y1), (prof[0][0] - 2.0, y0)], center=pc, segments=20, closed=True, rot=tilt)
    # The ring: a flat annulus r 104..150, tilted 18° like the bands.
    revolve(pring, [(104.0, -1.5), (150.0, -1.5), (150.0, 1.5), (104.0, 1.5)], center=pc, segments=28, closed=True, rot=tilt)
    # Home planet (cartoon): blue ball, green blobs, a cloud band. At +X = the viewer's LEFT, so it
    # sits on the far side of the ringed planet from the MOON BASE sign in the arrival view.
    hc = Vector((190.0, 180.0, 30.0))
    ellipsoid(ocean, tuple(hc), (44.0, 44.0, 44.0), rings=10, segments=16)
    for k, (yaw, pitch, size) in enumerate(((-30, 20, 16.0), (40, -10, 14.0), (10, 40, 10.0), (-60, -30, 12.0), (80, 25, 9.0))):
        a, p = math.radians(yaw), math.radians(pitch)
        d = Vector((math.sin(a) * math.cos(p), math.sin(p), -math.cos(a) * math.cos(p)))
        c = hc + d * 41.5
        ellipsoid(land, tuple(c), (size, size * 0.75, size), rings=4, segments=8)
    revolve(cloud, [(45.2, -4.0), (45.2, 4.0), (42.0, 4.0), (42.0, -4.0)], center=tuple(hc), segments=20, closed=True, rot=rot_z(12.0))
    return m


BUILDERS = {
    "Moon_Ground": build_ground,
    "Moon_LandingPlaza": build_landing_plaza,
    "Moon_RingPath": build_ring_path,
    "Moon_Trail": build_trail,
    "Moon_RocketFountain": build_rocket_fountain,
    "Moon_TitleSign": build_title_sign,
    "Moon_TeleportPad": build_teleport_pad,
    "Moon_EggStand": build_egg_stand,
    "Moon_Leaderboard": build_leaderboard,
    "Moon_PlotGround": build_plot_ground,
    "Moon_Path": build_path,
    "Moon_CraterRim": build_crater_rim,
    "Moon_EntranceArch": build_entrance_arch,
    "Moon_LockedSlot": build_locked_slot,
    "Moon_Crater": build_crater,
    "Moon_Rock": build_rock,
    "Moon_CrystalCluster": build_crystal_cluster,
    "Moon_Antenna": build_antenna,
    "Moon_BoundaryRidge": build_boundary_ridge,
    "Moon_PlanetBackdrop": build_planet_backdrop,
}
