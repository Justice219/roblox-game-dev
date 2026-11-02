"""
tiles.py — 16 x 16 stud ground tiles (the LEGO "baseplate" floor of every plot).

Pivot for every tile: centre of the TOP face (walk surface at y = 0; the slab hangs below).
Edges are chamfered so neighbouring tiles show a crisp seam, like plates snapped together.
Roads run along Z (B5 rotates tiles 90 deg for cross streets).

Tile_Grass     bright green plate
Tile_Road      asphalt plate, yellow centre dashes, white edge lines
Tile_Sidewalk  four 8 x 8 light-grey flagstones
Tile_Hazard    black plate with raised yellow diagonal hazard stripes (silo pads, loading zones)

Budget: <= 300 triangles per tile (a plot can hold a few hundred). For very large plain fields,
B5 may use one big primitive Part dressed with WorldMaterials.apply(part, "Studs") — identical
stud density by construction (see docs/world-art.md).
"""

from snkit.core import GRASS, HAZARD_BLACK, HAZARD_YELLOW, Model, ROAD, ROAD_LINE, SIDEWALK, WHITE
from snkit.kit import block, hazard_floor

SIZE = 16.0
THICK = 1.0


def _slab(piece, bevel=0.22):
    """Full-size tile slab whose top face is y = 0."""
    block(piece, (0, -THICK / 2, 0), (SIZE, THICK, SIZE), bevel=bevel)


def build_grass():
    m = Model("Tile_Grass", "centre of the top face (walk surface y = 0)", budget=300)
    _slab(m.piece("Grass", GRASS))
    return m


def build_road():
    m = Model("Tile_Road", "centre of the top face (walk surface y = 0); road runs along Z", budget=300)
    _slab(m.piece("Asphalt", ROAD))
    dashes = m.piece("Dashes", ROAD_LINE)
    for z in (-4.0, 4.0):
        block(dashes, (0, 0.04, z), (0.7, 0.16, 4.2), bevel=0.05)
    lines = m.piece("EdgeLines", WHITE)
    for x in (-6.9, 6.9):
        block(lines, (x, 0.04, 0), (0.5, 0.16, SIZE - 0.5), bevel=0.05)
    return m


def build_sidewalk():
    m = Model("Tile_Sidewalk", "centre of the top face (walk surface y = 0)", budget=300)
    slabs = m.piece("Slabs", SIDEWALK)
    half = SIZE / 4
    for x in (-half, half):
        for z in (-half, half):
            block(slabs, (x, -THICK / 2, z), (SIZE / 2 - 0.12, THICK, SIZE / 2 - 0.12), bevel=0.2)
    return m


def build_hazard():
    m = Model("Tile_Hazard", "centre of the top face (walk surface y = 0)", budget=300)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    block(black, (0, -THICK / 2 - 0.06, 0), (SIZE, THICK - 0.12, SIZE), bevel=0.22)
    # Raised yellow stripes; the black plate shows between them. Stripe tops are the walk surface.
    hazard_floor(yellow, None, (0, -0.12, 0), (SIZE, SIZE), 0.24, stripe=2.0, inset=0.45)
    return m


BUILDERS = {
    "Tile_Grass": build_grass,
    "Tile_Road": build_road,
    "Tile_Sidewalk": build_sidewalk,
    "Tile_Hazard": build_hazard,
}
