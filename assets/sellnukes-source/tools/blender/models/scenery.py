"""
scenery.py — stylised world scenery (B8e): the island ground everything stands on, the stepped sand
beach and the stud-water sea at the map edge, and cheap cartoon props for the wedges between plots
(hills, pine trees, clouds on sticks, rocks, flower patches, ponds).

The world is a toy island (missiles-vs-cities references): hub + ring road + 8 plots sit on raised
stud "baseplates" (top y = 0) over a darker island ground (top y = -0.4) that reaches r = 836,
then a stepped beach down to the water (top y = -2.4) that runs to r = 2000.

Models (pivot noted per model; HubLayout.scenery places them):
    Scenery_IslandGround  ONE disc r = 836, top y = -0.4 (pivot = world origin)
    Scenery_BeachArc      x8: 45 deg of beach r 828-874 centred on +Z (pivot = world origin;
                          spawn at yaw (i-1)*45 deg): dry sand step, chunky sand blocks, wet sand,
                          white foam line at the water's edge
    Scenery_Water         x8: 45 deg of sea r 866-2000 centred on +Z, top y = -2.4, StudsLarge
    Scenery_Hill          stepped toy hill (dirt sides, grass caps) ~41 x 33, 13 tall; pivot ground
    Scenery_HillSmall     two-tier hill ~23 x 18, 6 tall
    Scenery_TreePine      stacked-cone pine ~17 tall
    Scenery_Cloud         cartoon cloud on a wooden stick (theatre-prop style), top ~27
    Scenery_CloudBig      the same at 2x for the shoreline, top ~54
    Scenery_Rock          chunky grey boulder group
    Scenery_Flowers       patch of 7 flowers; `Petals` TINTED (pink / yellow / purple per spawn)
    Scenery_Pond          round pond: sand rim (top y = 0.6), water (top 0.35), lily pads
Ground-pivot props are placed at y = -0.4 (island ground top) by HubLayout.

Budgets: ground/water/beach <= 1,500 (one or eight instances, huge), props <= 1,500.
"""

import math

from snkit.core import CONCRETE_DARK, GRASS, GRASS_DARK, LEAF, Model, PINK, WHITE, WOOD, WOOD_DARK, YELLOW
from snkit.kit import block
from snkit.shapes import bar, box, cylinder, ellipsoid, rot_y

from models.hub import HALF, WATER, polar, ring, rrect_outline, sector_outline, slab

ISLAND_R = 836.0  # island ground radius
ISLAND_TOP = -0.4  # island ground top (plots / plaza sit 0.4 higher)
WATER_TOP = -2.4  # sea surface
SEA_R = 2000.0  # sea outer radius (MeshPart axis limit is 2048)

SAND = (242, 214, 142)
SAND_WET = (226, 188, 120)
SOIL = (178, 122, 74)
SEA = (66, 160, 236)
PINE = (46, 150, 84)


def build_island_ground():
    """The island: one big dark-green stud disc under the whole map (top y = -0.4)."""
    m = Model("Scenery_IslandGround", "world origin; disc r = 836, top y = -0.4", budget=800)
    ring(m.piece("Grass", GRASS_DARK), 0.0, ISLAND_R, -3.4, ISLAND_TOP, 72, chamfer=0.6)
    return m


def build_beach_arc():
    """45 deg of stepped beach centred on +Z: dry sand, chunky sand blocks, wet sand, foam line."""
    m = Model("Scenery_BeachArc", "world origin; arc covers yaw -22.5..+22.5 deg, r 828-874 (dry/wet/foam bands)", budget=1500)
    sand = m.piece("Sand", SAND)
    wet = m.piece("SandWet", SAND_WET)
    foam = m.piece("Foam", WHITE)
    # Radially DISJOINT bands (dry 828-850, wet 850-868, foam 868-874; the sea starts at 874), so
    # no two layers share an end-cap plane at the sector ends (z-fight rule, docs/areas-art.md).
    slab(sand, sector_outline(828.0, 850.0, -HALF, HALF, 12), -3.4, -0.7, chamfer=0.3)
    slab(wet, sector_outline(850.0, 868.0, -HALF, HALF, 12), -3.6, -1.6, chamfer=0.3)
    slab(foam, sector_outline(868.0, 874.0, -HALF, HALF, 12), -2.8, -2.15, chamfer=0.12)
    # Chunky voxel sand blocks along the dry step (deterministic layout, like stacked toy plates).
    for i, (t, dr, w, h) in enumerate(
        ((0.04, 0, 9, 1.0), (0.14, 4, 7, 0.6), (0.25, -2, 11, 1.3), (0.37, 3, 8, 0.8), (0.49, -1, 10, 1.1),
         (0.61, 5, 6, 0.6), (0.72, 0, 12, 1.2), (0.84, 3, 8, 0.7), (0.95, -2, 9, 1.0))
    ):
        a = -HALF + 2 * HALF * t
        r = 843.0 + dr
        x, z = polar(r, a)
        target = sand if i % 3 else wet
        block(target, (x, -0.9 + h / 2, z), (w, h + 0.4, 6.0), bevel=0.25, rot=rot_y(math.degrees(a)))
    return m


def build_water():
    """45 deg of sea centred on +Z from the beach to the horizon (StudsLarge = toy water plate)."""
    m = Model("Scenery_Water", "world origin; sector yaw -22.5..+22.5 deg, r 874-2000, top y = -2.4", budget=400)
    slab(m.piece("Water", SEA, material="StudsLarge"), sector_outline(874.0, SEA_R, -HALF, HALF, 12), -3.2, WATER_TOP, chamfer=0.0)
    return m


def _hill(m, tiers):
    """Stepped hill: rounded dirt tiers with slightly overhanging grass caps. tiers = (w, d, r, h, ox, oz)."""
    dirt = m.piece("Dirt", SOIL)
    grass = m.piece("Grass", GRASS)
    y = 0.0
    for w, d, r, h, ox, oz in tiers:
        slab(dirt, rrect_outline(w, d, r, 3, ox, oz), y - 0.4, y + h - 0.6, chamfer=0.3)
        slab(grass, rrect_outline(w + 0.8, d + 0.8, r + 0.4, 3, ox, oz), y + h - 0.75, y + h, chamfer=0.3)
        y += h


def build_hill():
    """Four-tier toy hill (~41 x 33 footprint, ~13 tall)."""
    m = Model("Scenery_Hill", "ground centre; footprint ~41 x 33, top y ~ 13", budget=1500)
    _hill(m, ((40, 32, 8, 3.6, 0, 0), (30, 23, 7, 3.4, 1.5, -1), (20, 15, 5, 3.2, 2.5, 0.5), (11, 8, 3, 2.8, 2, 1)))
    return m


def build_hill_small():
    """Two-tier small hill (~23 x 18, ~6 tall)."""
    m = Model("Scenery_HillSmall", "ground centre; footprint ~23 x 18, top y ~ 6.4", budget=800)
    _hill(m, ((22, 17, 6, 3.4, 0, 0), (12, 9, 3.5, 3.0, -1.2, 0.8)))
    return m


def build_tree_pine():
    """Stacked-cone toy pine (~17 tall)."""
    m = Model("Scenery_TreePine", "ground centre; top y ~ 17", budget=600)
    trunk = m.piece("Trunk", WOOD_DARK)
    leaves = m.piece("Leaves", PINE)
    cylinder(trunk, (0.0, 0.0, 0.0), (0.0, 4.0, 0.0), 0.75, segments=8)
    for y0, r0, h in ((3.0, 4.6, 6.0), (6.8, 3.6, 5.4), (10.2, 2.6, 5.0), (13.4, 1.5, 3.6)):
        cylinder(leaves, (0.0, y0, 0.0), (0.0, y0 + h, 0.0), r0, segments=10, radius_b=0.25)
    return m


def _cloud(m, s):
    """Cartoon cloud (flattened stud blobs) on a wooden stick; s = scale."""
    pole = m.piece("Pole", WOOD)
    cloud = m.piece("Cloud", WHITE)
    block(pole, (0.0, 0.5 * s, 0.0), (2.6 * s, 1.0 * s, 2.6 * s), bevel=0.2 * s)
    bar(pole, (0.0, 1.0 * s, 0.0), (0.0, 20.0 * s, 0.0), 0.7 * s)
    for (x, y), (rx, ry) in (
        ((-4.6, 22.0), (3.6, 3.0)),
        ((0.0, 23.6), (5.0, 4.3)),
        ((4.9, 22.3), (3.9, 3.2)),
        ((1.8, 20.8), (4.4, 2.4)),
        ((-2.0, 20.9), (4.0, 2.3)),
    ):
        ellipsoid(cloud, (x * s, y * s, 0.0), (rx * s, ry * s, 2.4 * s), rings=6, segments=12)


def build_cloud():
    """Cloud on a stick (~14 wide, top ~27)."""
    m = Model("Scenery_Cloud", "ground centre (stick foot); cloud faces -Z/+Z, top y ~ 27.9", budget=1500)
    _cloud(m, 1.0)
    return m


def build_cloud_big():
    """Shoreline cloud on a stick, 2x (~28 wide, top ~56)."""
    m = Model("Scenery_CloudBig", "ground centre (stick foot); top y ~ 55.8", budget=1500)
    _cloud(m, 2.0)
    return m


def build_rock():
    """Chunky grey boulder group (three chamfered blocks)."""
    m = Model("Scenery_Rock", "ground centre; ~7 x 5 footprint, top y ~ 3", budget=400)
    rock = m.piece("Rock", CONCRETE_DARK)
    block(rock, (0.0, 1.4, 0.0), (4.4, 3.0, 3.6), bevel=0.6, rot=rot_y(15))
    block(rock, (2.3, 0.9, 1.3), (2.6, 2.0, 2.4), bevel=0.45, rot=rot_y(-20))
    block(rock, (-2.4, 0.6, 1.1), (1.8, 1.3, 1.6), bevel=0.35, rot=rot_y(40))
    return m


def build_flowers():
    """Patch of 7 cartoon flowers; Petals tinted per spawn (pink default)."""
    m = Model("Scenery_Flowers", "ground centre; ~6 x 6 patch, top y ~ 2.4; Petals tinted", budget=1000)
    stems = m.piece("Stems", LEAF)
    petals = m.piece("Petals", PINK, tinted=True)
    centres = m.piece("Centres", YELLOW)
    spots = ((0.0, 0.0, 2.0), (1.9, 0.8, 1.5), (-1.7, 1.1, 1.7), (0.9, -1.8, 1.3), (-1.2, -1.5, 1.8), (2.4, -1.1, 1.2), (-2.6, -0.2, 1.4))
    for x, z, h in spots:
        bar(stems, (x, 0.0, z), (x, h, z), 0.22)
        box(stems, (x + 0.35, 0.5, z), (0.6, 0.12, 0.35))
        # Two crossed chamfered petal plates read as a 4-petal toy flower at a quarter of the cost.
        block(petals, (x, h + 0.1, z), (1.3, 0.22, 0.5), bevel=0.06)
        block(petals, (x, h + 0.1, z), (0.5, 0.22, 1.3), bevel=0.06)
        box(centres, (x, h + 0.2, z), (0.36, 0.24, 0.36))
    return m


def build_pond():
    """Round pond: sand rim, cartoon water, lily pads with two pink flowers."""
    m = Model("Scenery_Pond", "ground centre; rim r 22.5 (top y = 0.6), water r 19.2 (top y = 0.35)", budget=1200)
    rim = m.piece("Rim", SAND)
    water = m.piece("Water", WATER, material="Smooth")
    lily = m.piece("Lily", LEAF)
    flower = m.piece("Flower", PINK)
    ring(rim, 19.0, 22.5, 0.0, 0.6, 32, chamfer=0.25)
    ring(water, 0.0, 19.2, 0.0, 0.35, 32, chamfer=0.0)
    for i, (r, a, s) in enumerate(((8.0, 0.4, 1.7), (12.5, 1.9, 1.4), (5.0, 3.1, 1.5), (14.0, 4.2, 1.8), (10.0, 5.4, 1.3))):
        x, z = polar(r, a)
        ring(lily, 0.0, s, 0.35, 0.5, 10, chamfer=0.0, center=(x, z))
        if i in (0, 3):
            ellipsoid(flower, (x, 0.85, z), (0.55, 0.45, 0.55), rings=4, segments=8)
    return m


BUILDERS = {
    "Scenery_IslandGround": build_island_ground,
    "Scenery_BeachArc": build_beach_arc,
    "Scenery_Water": build_water,
    "Scenery_Hill": build_hill,
    "Scenery_HillSmall": build_hill_small,
    "Scenery_TreePine": build_tree_pine,
    "Scenery_Cloud": build_cloud,
    "Scenery_CloudBig": build_cloud_big,
    "Scenery_Rock": build_rock,
    "Scenery_Flowers": build_flowers,
    "Scenery_Pond": build_pond,
}
