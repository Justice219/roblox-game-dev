"""
plotframe.py — the reusable PLOT FRAME every one of the 8 plots is built from (B8e).

Plot-local frame (docs/superpowers/plans/2026-10-30-sellnukes-build.md "World layout"):
    origin = plot entrance centre where the plot road touches the ring road (world r = 260),
    +Z points away from the hub, +X is the player's right when walking outward, +Y up.
    Footprint x in [-80, 80], z in [0, 520]; central road |x| <= 8; area slots beside it.
    The ring road's outer edge is the circle of radius 260 around the hub, which in plot-local
    coordinates is z = sqrt(260^2 - x^2) - 260 (0 at the road, -12.6 at x = +-80); the plot ground
    and road follow that curve so there is no gap between the plot and the ring road.

Models (pivot = plot-local origin unless stated; HubLayout.plotFrame places them):
    Plot_Ground        two grass plates x in [-80, -10] and [10, 80] (top y = 0), curved front
    Plot_Road          asphalt |x| <= 8 + raised white-grey curbs 8 <= |x| <= 10 (top y = 0.4),
                       yellow centre dashes, white edge lines; full 520 length
    Plot_Border        low concrete wall just OUTSIDE the footprint (x = +-[80, 81.6], z = [520, 521.6])
                       with posts; `Cap` is TINTED with the plot colour (identity from afar)
    Plot_EntranceArch  pivot = plot-local (0, 0, 4). Two pillars at x = +-13, beam over the road,
                       `OwnerSign` piece = two flat panels (front z = -2.0 faces the hub, back z = +2.0
                       faces the plot) => SurfaceGui on Front and Back; `Accent` tinted (plot colour);
                       mini nuke on top; "YOU" marker anchor at plot-local (0, 31, 4).
    Plot_LockedSlot    pivot = SLOT-local origin (road-side edge midpoint of an area slot; +Z_s away
                       from the road, front -Z faces the road). Construction fence across the slot
                       front (x_s in [-48, 48] at z_s = 3), cones, a "COMING SOON" board (`Sign`,
                       front at z_s = 4.0) under a big padlock, and giant toy bricks waiting to be
                       built. Shown on every slot that is still locked.

Budgets: ground/road/border are one model per plot (<= 2,500), arch <= 3,500, locked slot <= 2,000
(up to 9 per plot are on screen for a new player, so it is kept lean).
"""

import math

from snkit.core import (
    CHARCOAL,
    CONCRETE,
    CREAM,
    GLOW_GREEN,
    GRASS,
    LAMP_WARM,
    Model,
    ORANGE,
    ROAD,
    ROAD_LINE,
    SIDEWALK,
    SKY_BLUE,
    WHITE,
    YELLOW,
)
from snkit.kit import block, nuke_body, sign_frame
from snkit.shapes import box, cylinder, ellipsoid, ring_tube

from models.hub import STONE, bulb, lin, slab

ROAD_OUT_R = 260.0  # ring road outer radius (plot origin sits on it)
PLOT_HALF = 80.0  # plot half-width
PLOT_LEN = 520.0  # plot length along +Z
ROAD_HALF = 8.0  # asphalt half-width
CURB_HALF = 10.0  # outer edge of the road curbs (= area slot inner edge)
CURB_TOP = 0.4  # raised curb height


def front_z(x):
    """Plot-local z of the ring road's outer edge at x (the plot's curved front)."""
    return math.sqrt(ROAD_OUT_R * ROAD_OUT_R - x * x) - ROAD_OUT_R


def band_outline(x0, x1, z1, segments=6):
    """Plate from x0 to x1 (x0 < x1) whose front follows the ring road and back is z1; inset-aware."""

    def at(d):
        a, b = x0 + d, x1 - d
        front = [(x, front_z(x) + d) for x in lin(a, b, segments)]
        return front + [(b, z1 - d), (a, z1 - d)]

    return at


def build_ground():
    """Grass plates either side of the road corridor (|x| <= 10), top y = 0."""
    m = Model("Plot_Ground", "plot-local origin (entrance centre on the ring road); top y = 0", budget=600)
    grass = m.piece("Grass", GRASS)
    slab(grass, band_outline(-PLOT_HALF, -CURB_HALF, PLOT_LEN), -1.0, 0.0, chamfer=0.3)
    slab(grass, band_outline(CURB_HALF, PLOT_HALF, PLOT_LEN), -1.0, 0.0, chamfer=0.3)
    return m


def rect_outline(x0, x1, z0, z1):
    """Axis-aligned rectangle (inset-aware) for straight-edged slabs."""

    def at(d):
        return [(x0 + d, z0 + d), (x1 - d, z0 + d), (x1 - d, z1 - d), (x0 + d, z1 - d)]

    return at


def build_road():
    """
    Central plot road: asphalt, raised curbs, yellow centre dashes, white edge lines.

    Layers (z-fight rule, docs/areas-art.md): asphalt top 0, edge lines +0.03, dashes +0.04, curbs
    +0.4. The front is STRAIGHT at z = 0 and butts the ring road's junction mouth (Hub_RingRoadArc,
    straight edge at world r = 260) edge to edge: no overlap, no curved same-height seam.
    """
    m = Model("Plot_Road", "plot-local origin; road |x| <= 8 from z = 0 to 520; curbs to |x| = 10 (top y = 0.4)", budget=1500)
    asphalt = m.piece("Asphalt", ROAD)
    curb = m.piece("Curb", SIDEWALK)
    dashes = m.piece("Dashes", ROAD_LINE)
    lines = m.piece("Lines", WHITE)
    # Asphalt runs 0.6 into the back border wall and the curbs start 0.1 over the ring road's mouth,
    # so even MeshLibrary's primitive fallback (one box per piece) never puts the asphalt and curb
    # end faces on one plane.
    slab(asphalt, rect_outline(-ROAD_HALF, ROAD_HALF, 0.0, PLOT_LEN + 0.6), -1.0, 0.0, chamfer=0.15)
    for x0, x1 in ((-CURB_HALF, -ROAD_HALF), (ROAD_HALF, CURB_HALF)):
        slab(curb, rect_outline(x0, x1, -0.1, PLOT_LEN), -1.0, CURB_TOP, chamfer=0.15)
    z = 8.0
    while z < PLOT_LEN - 6.0:
        box(dashes, (0.0, -0.03, z), (0.6, 0.14, 5.0))
        z += 12.0
    for x in (-7.0, 7.0):
        box(lines, (x, -0.035, PLOT_LEN / 2 + 1.0), (0.4, 0.13, PLOT_LEN - 4.0))
    return m


def build_border():
    """
    Low concrete wall round the sides and back with posts; tinted caps = plot colour. The wall sits
    just OUTSIDE the plot footprint (x = +-[80, 81.6], z = [520, 521.6]; posts to 82.4) so area
    floors and walls that run to the slot edge never share a face plane with it (z-fight rule).
    """
    m = Model("Plot_Border", "plot-local origin; walls x = +-[80, 81.6], z = [520, 521.6], top y = 1.5 (posts 2.6)", budget=2500)
    wall = m.piece("Wall", CONCRETE)
    cap = m.piece("Cap", SKY_BLUE, tinted=True)
    z0 = front_z(PLOT_HALF) + 1.2
    side_len = PLOT_LEN + 1.6 - z0
    for x in (-80.8, 80.8):
        block(wall, (x, 0.45, z0 + side_len / 2), (1.6, 1.5, side_len), bevel=0.15)
        block(cap, (x, 1.35, z0 + side_len / 2), (1.9, 0.3, side_len), bevel=0.1)
    block(wall, (0.0, 0.45, 520.8), (163.2, 1.5, 1.6), bevel=0.15)
    block(cap, (0.0, 1.35, 520.8), (163.5, 0.3, 1.9), bevel=0.1)
    posts = [(x, z) for x in (-81.2, 81.2) for z in lin(z0 + 0.6, 521.2, 8)]
    posts += [(x, 521.2) for x in lin(-52.8, 52.8, 4)]
    for x, z in posts:
        block(wall, (x, 1.0, z), (2.4, 2.4, 2.4), bevel=0.2)
        block(cap, (x, 2.4, z), (2.7, 0.4, 2.7), bevel=0.12)
    return m


def build_entrance_arch():
    """Entrance arch over the plot road with the owner sign (both faces) and a mini nuke on top."""
    m = Model(
        "Plot_EntranceArch",
        "plot-local (0, 0, 4) on the ground; OwnerSign panels: Front face z = -2.0 (toward hub), Back z = +2.0",
        budget=3500,
    )
    base = m.piece("Base", CHARCOAL)
    stone = m.piece("Stone", STONE)
    accent = m.piece("Accent", SKY_BLUE, tinted=True)
    sign = m.piece("OwnerSign", CREAM)
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    for x in (-13.0, 13.0):
        block(base, (x, 0.8, 0.0), (5.0, 1.6, 5.0), bevel=0.25)
        block(stone, (x, 10.1, 0.0), (4.0, 17.0, 4.0), bevel=0.3)
        for y in (6.0, 11.0):
            block(accent, (x, y, 0.0), (4.5, 0.8, 4.5), bevel=0.15)
        block(accent, (x, 20.2, 0.0), (5.2, 1.2, 5.2), bevel=0.2)
        ellipsoid(accent, (x, 22.2, 0.0), (1.5, 1.5, 1.5), rings=6, segments=10)
    block(stone, (0.0, 17.3, 0.0), (30.0, 4.6, 3.4), bevel=0.3)
    for z in (-1.85, 1.85):
        block(sign, (0.0, 17.3, z), (22.0, 3.6, 0.3), bevel=0.06)
    for z in (-1.25, 1.25):
        for x in lin(-10.5, 10.5, 10):
            bulb(bulbs, (x, 19.85, z), radius=0.34)
    nuke_body(accent, stone, base, core, base=(0.0, 19.6, 0.0), length=7.0, radius=1.6, segments=14)
    return m


def build_locked_slot():
    """'Coming soon' placeholder for a locked area slot: fence, cones, sign, padlock, toy bricks."""
    m = Model(
        "Plot_LockedSlot",
        "SLOT-local origin (road-side edge midpoint, +Z away from the road); Sign front z = 4.0 faces the road",
        budget=2000,
    )
    posts = m.piece("Posts", CHARCOAL)
    orange = m.piece("Barrier", ORANGE)
    white = m.piece("Stripe", WHITE)
    sign = m.piece("Sign", CREAM)
    lock = m.piece("Lock", YELLOW)
    xs = lin(-48.0, 48.0, 8)
    for x in xs:
        block(posts, (x, 1.9, 3.0), (0.7, 3.8, 0.7), bevel=0.1)
        box(posts, (x, 0.25, 3.0), (1.6, 0.5, 1.6))
    for k in range(8):
        x = (xs[k] + xs[k + 1]) / 2
        top, low = (orange, white) if k % 2 == 0 else (white, orange)
        box(top, (x, 3.0, 2.6), (11.4, 0.9, 0.3))  # thin boards: chamfers would not read, save tris
        box(low, (x, 1.8, 2.6), (11.4, 0.9, 0.3))
    # "COMING SOON" board on legs + padlock topper.
    sign_frame(posts, sign, (0.0, 9.2, 4.4), (14.0, 5.0), border=0.5, depth=0.6, posts=0.7)
    block(lock, (0.0, 13.3, 4.4), (3.4, 2.8, 1.2), bevel=0.25)
    ring_tube(posts, (0.0, 14.9, 4.4), 1.1, 0.45, 0.5, segments=12, axis="Z")
    block(posts, (0.0, 13.1, 3.75), (0.45, 0.95, 0.12), bevel=0.04)
    # Traffic cones in front of the fence.
    for x in (-40.0, -24.0, 24.0, 40.0):
        box(orange, (x, 0.12, 1.0), (1.6, 0.24, 1.6))
        cylinder(orange, (x, 0.24, 1.0), (x, 2.4, 1.0), 0.72, segments=8, radius_b=0.12)
        cylinder(white, (x, 1.1, 1.0), (x, 1.5, 1.0), 0.5, segments=8, radius_b=0.43)
    # Giant toy bricks inside the slot, waiting to be built.

    def brick(piece, cx, cy, cz, nx, nz):
        w, d, h = nx * 2.0, nz * 2.0, 2.4
        block(piece, (cx, cy + h / 2, cz), (w, h, d), bevel=0.15)
        for i in range(nx):
            for j in range(nz):
                sx, sz = cx - w / 2 + 1.0 + 2.0 * i, cz - d / 2 + 1.0 + 2.0 * j
                cylinder(piece, (sx, cy + h, sz), (sx, cy + h + 0.45, sz), 0.6, segments=6)

    brick(orange, -22.0, 0.0, 26.0, 4, 2)
    brick(lock, -20.0, 2.4, 26.5, 2, 2)
    brick(white, 26.0, 0.0, 34.0, 3, 2)
    return m


BUILDERS = {
    "Plot_Ground": build_ground,
    "Plot_Road": build_road,
    "Plot_Border": build_border,
    "Plot_EntranceArch": build_entrance_arch,
    "Plot_LockedSlot": build_locked_slot,
}
