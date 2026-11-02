"""
area08.py — Area 8 "Nuke Megastore" set (spec §3.8): a bright candy shopping mall where the toy
nukes are sold. Two-storey storefront with an open ground floor (the Megastore Checkout producer),
shelves of boxed toy nukes, twin escalators up to the balcony, the giant mascot statue "Nukey"
(a happy cartoon nuke waving and carrying a shopping bag), a rooftop billboard, a food court with a
giant donut and a three-level parking garage full of toy cars.

Kid-friendly (spec §1): pastel/candy palette, a smiling mascot, toy cars, no real brands.

SLOT FRAME (docs/superpowers/plans/2026-10-30-sellnukes-build.md "World layout"):
    origin = slot road-side edge midpoint at ground (y = 0), +Z away from the road, +X along it.
    Slot x in [-52, 52], z in [0, 70], height budget 80. Pads sit in the road strip z in [2, 16].
    Plaza top DECK_TOP = 0.5; every prop below stands ON the plaza (pivot y = 0.5).

Model keys (layout: src/shared/Config/AreaLayouts/Area08.luau; every front = -Z = road):
    SLOT-ORIGIN pivot (place at CFrame.identity):
        A8_Plaza          candy checker plaza, curbs, sky-blue carpet walkway, lamps, planters  (base)
    OWN pivot = ground centre (place at (x, DECK_TOP, z)):
        A8_EntryArch      candy-cane pillars, lettered "NUKE / MEGASTORE" sign, star, balloons    (base)
        A8_MascotNukey    giant Nukey statue on a pedestal with a lettered "NUKEY" plaque
        A8_FoodCourt      "GLOW BITES" kiosk (lettered menu sign), giant donut, umbrella tables
        A8_ParkingGarage  3-level parking structure, 2 ramps, 5 parked toy cars, "P" sign (piece
                          Sign), ticket barrier arm BarrierYellow/BarrierBlack authored DOWN (R56:
                          the client lifts it about the hinge (-4.3, 2.4, -22.8), arm along -X)
        A8_ShopperCar     drivable blue toy car (R56): TyresF/TyresR + HubsF/HubsR, BrakeLights,
                          IndicatorL/R; pivot = its ground centre, nose -Z (layout yaws it 90)
        A8_StoreManager   friendly shopkeeper robot with a basket (Manager)
    STORE-ORIGIN pivot = ground centre of the store footprint (48 x 26, facade at local z = -13):
        A8_Storefront     the store shell + balcony + checkout counters (producer), lettered roof sign
        A8_Shelves        four gondola shelves of boxed toy nukes + hanging SALE boards
        A8_Escalators     twin escalators from the plaza (local z -38) up to the balcony (y 13)
        A8_Billboard      rooftop billboard: candy nuke art + lettered "GLOWING DEALS!"

Budgets (docs/world-art.md §4): landmark buildings <= 6,000 tris, props/furniture <= 3,000-4,500.

Piece names drive client animation (src/shared/Config/WorldFxConfig.luau): `Core` / `Bulb` get a
pulsing light, `Glow` bobs, `Belt` scrolls its studs, `Wheel` spins. Static glowing detail is
therefore named `RegisterGlow` / `SkirtLight` / `MenuGlow`, checkout belts `Checkout`, car wheels
`Wheels` (parked toys must not spin). The drivable A8_ShopperCar uses the R56 vehicle contract
instead (`TyresF/R` + `HubsF/R` spun by the client's vehicle driver; models/area03.py).
"""

import math

from mathutils import Vector

from models.area01 import FONT_ROWS, block_text, text_cells
from models.area07 import sign_text
from snkit.core import (
    CHARCOAL,
    CONCRETE,
    CONCRETE_DARK,
    CREAM,
    DARK_STEEL,
    DEEP_BLUE,
    GLASS,
    GLOW_GREEN,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LAMP_WARM,
    LEAF,
    LIME,
    MINT,
    Model,
    ORANGE,
    PINK,
    PURPLE,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    WHITE,
    WOOD,
    WOOD_DARK,
    YELLOW,
)
from snkit.kit import block, disc, lamp, nuke_body, sign_frame, tree, trefoil
from models.area03 import AMBER, axle_wheels  # R56 drivable-vehicle kit (per-axle wheels + hubs)
from snkit.shapes import bar, box, clip_convex, cylinder, ellipsoid, prism, revolve, rot_x, rot_y

# ------------------------------------------------------------------------------------------------
# Area constants (mirrored in src/shared/Config/AreaLayouts/Area08.luau — keep both in sync)
# ------------------------------------------------------------------------------------------------

DECK_TOP = 0.5
SLOT_W, SLOT_D = 104.0, 70.0
SLOT_PIVOT = "slot origin (road-side edge midpoint, ground y = 0); +Z away from the road; place at CFrame.identity"
STORE_PIVOT = "store origin: ground centre of the 48 x 26 store footprint (plaza top); facade at z = -13 faces -Z"

SW, SD = 48.0, 26.0  # store footprint (x -24..24, z -13..13)
F1, F2 = 12.0, 22.0  # first-floor slab bottom (ceiling of the shop), roof slab bottom
BALCONY_Z = -17.0  # balcony front edge (local z); balcony top y = F1 + 1 = 13
ENTRANCE_HALF = 13.0  # open shop entrance x in [-13, 13]
ESC_GAP = (10.5, 20.5)  # balcony railing gap (local x) where the escalators arrive
ESC_LANES = (13.0, 18.0)  # escalator lane centres (local x)
ESC_W = 4.4  # lane width
ESC_BOTTOM, ESC_TOP = (-35.0, 0.3), (-17.5, F1 + 1.0)  # (z, y) of the walking incline ends

# Area-local accents (not in the shared palette): plaza tiles, blush pink tile, cyan robot eyes.
TILE_A = (240, 234, 222)
TILE_B = (255, 206, 222)
CYAN = (120, 230, 255)


def _star(piece, center, r_out, r_in, depth, points=5):
    """
    Flat star (faces -Z) built from convex parts only: a central polygon of inner points + one
    triangle per spike, so triangulation can never fold a concave outline.
    """
    cx, cy, cz = center
    inner, outer = [], []
    for i in range(points):
        a_out = math.pi / 2 + 2 * math.pi * i / points
        a_in = a_out + math.pi / points
        outer.append((cx + r_out * math.cos(a_out), cy + r_out * math.sin(a_out), cz))
        inner.append((cx + r_in * math.cos(a_in), cy + r_in * math.sin(a_in), cz))
    prism(piece, inner, (0, 0, 1), depth)
    for i in range(points):
        prism(piece, [inner[i - 1], outer[i], inner[i]], (0, 0, 1), depth)


def _front_disc(piece, center, radius, depth, segments=16):
    """Disc whose flat face looks -Z (badges, stickers, sign dots). center = disc centre."""
    revolve(
        piece,
        [(0.0, -depth / 2), (radius, -depth / 2), (radius, depth / 2), (0.0, depth / 2)],
        center=center,
        segments=segments,
        rot=rot_x(90),
    )


# ------------------------------------------------------------------------------------------------
# Base (built by A8_EntryArch, the Area 7 unlock pad)
# ------------------------------------------------------------------------------------------------


def build_plaza():
    """Candy checker plaza (16 chamfered tiles), white curbs, sky-blue carpet walkway with white
    edging, four warm lamps along the walkway, two planters with toy trees at the front corners.

    The lamp poles are their own piece ("Poles", not "Lamp*": WorldFx would light a Lamp* piece):
    in the low "Curb" piece their 7-stud height made Curb's bounding box cover the whole slot up
    to y 7, which blocks the producer billboard's clear-space test everywhere (owner R31 / R32,
    tests/billboard-clearance.luau)."""
    m = Model("A8_Plaza", SLOT_PIVOT + "; plaza top y = 0.5", budget=4500)
    tile_a = m.piece("TileA", TILE_A)
    tile_b = m.piece("TileB", TILE_B)
    curb = m.piece("Curb", WHITE)
    poles = m.piece("Poles", WHITE)
    walk = m.piece("Walk", SKY_BLUE)
    cage = m.piece("Pink", PINK)
    bulb = m.piece("Bulbs", LAMP_WARM, material="Neon")
    trunk = m.piece("Trunk", WOOD_DARK)
    leaves = m.piece("Leaves", LEAF)
    cols, rows = 4, 4
    pw, pd = SLOT_W / cols, SLOT_D / rows
    for i in range(cols):
        for j in range(rows):
            piece = tile_a if (i + j) % 2 == 0 else tile_b
            block(piece, (-SLOT_W / 2 + pw * (i + 0.5), 0.15, pd * (j + 0.5)), (pw, 0.7, pd), bevel=0.14)
    block(curb, (0, 0.65, SLOT_D - 0.6), (SLOT_W, 0.7, 1.2), bevel=0.14)
    for s in (-1, 1):
        block(curb, (s * (SLOT_W / 2 - 0.6), 0.65, SLOT_D / 2 - 0.6), (1.2, 0.7, SLOT_D - 1.2), bevel=0.14)
    # Carpet walkway from the arch to the store entrance (z 0 .. 42.5) with white edging.
    block(walk, (0, 0.52, 21.25), (11.0, 0.12, 42.5), bevel=0.02)
    for s in (-1, 1):
        block(curb, (s * 5.75, 0.54, 21.25), (0.5, 0.16, 42.5), bevel=0.03)
    for z in (22.0, 34.0):
        for s in (-1, 1):
            lamp(poles, cage, bulb, (s * 8.5, DECK_TOP, z), height=7.0, bulb_radius=0.55)
    # Planters with toy trees at the front corners (clear of the pad row and the garage).
    for s in (-1, 1):
        block(cage, (s * 48.0, DECK_TOP + 0.7, 17.0), (4.0, 1.4, 4.0), bevel=0.25)
        block(leaves, (s * 48.0, DECK_TOP + 1.42, 17.0), (3.4, 0.2, 3.4), bevel=0.04)
        tree(trunk, leaves, (s * 48.0, DECK_TOP + 1.4, 17.0), height=7.0, crown=3.2)
    return m


def build_entry_arch():
    """Candy-cane striped round pillars, yellow beam, lettered "NUKE / MEGASTORE" sign, star, balloons."""
    m = Model("A8_EntryArch", "ground centre between the pillars (plaza top); walk through toward +Z; Sign faces -Z", budget=4000)
    white = m.piece("White", WHITE)
    pink = m.piece("Pink", PINK)
    yellow = m.piece("Yellow", YELLOW)
    sign = m.piece("Sign", CREAM)
    blue = m.piece("Blue", SKY_BLUE)
    letters = m.piece("Letters", PURPLE, material="Smooth")
    px = 7.6  # same pillar spacing as every entry arch (pads start at x = +-13.5)
    for s in (-1, 1):
        block(white, (s * px, 0.5, 0), (3.4, 1.0, 3.4), bevel=0.2)
        y, i = 1.0, 0
        while y < 15.0 - 1e-6:  # 8 candy-cane bands: plain 12-sided drums (44 tris each, budget)
            cylinder(pink if i % 2 == 0 else white, (s * px, y, 0), (s * px, y + 1.75, 0), 1.3, segments=12)
            y += 1.75
            i += 1
        disc(yellow, (s * px, 15.0, 0), 1.7, 0.8, segments=12, bevel=0.2)
        # Balloon bunch tied to each beam end, floating OUTSIDE the sign (sign spans x +-8).
        anchor = (s * 9.5, 17.5, 0)
        for (dx, dz, h, piece) in ((0.0, 0.3, 2.4, pink), (1.0, -0.3, 3.2, blue), (0.4, 0.5, 4.1, yellow)):
            top = (s * (10.4 + dx), 17.5 + h, dz)
            bar(white, anchor, top, 0.08)
            ellipsoid(piece, (top[0], top[1] + 1.05, top[2]), (0.85, 1.05, 0.85), rings=5, segments=8)
            ellipsoid(piece, (top[0], top[1] + 0.02, top[2]), (0.18, 0.14, 0.18), rings=3, segments=5)
    block(yellow, (0, 16.6, 0), (19.6, 1.8, 2.2), bevel=0.22)
    for i in range(7):  # pink dots along the beam front
        _front_disc(pink, (-7.2 + i * 2.4, 16.6, -1.15), 0.4, 0.12, segments=8)
    sign_c, sign_size = (0, 20.4, -0.3), (16.0, 5.8)
    sign_frame(pink, sign, sign_c, sign_size, border=0.6, depth=0.7)
    sign_text(letters, ["NUKE", "MEGASTORE"], sign_c, sign_size, 0.6, 0.7, both_sides=True)  # R17: both faces
    _star(yellow, (0, 24.7, -0.3), 1.7, 0.75, 0.6)
    return m


# ------------------------------------------------------------------------------------------------
# Storefront (producer: Megastore Checkout)
# ------------------------------------------------------------------------------------------------


def build_storefront():
    """
    Two-storey mall shop. Ground floor: open 26-wide entrance between pink pillars, glass display
    windows either side, three checkout counters (the producer) with lanes between them. First
    floor: glass curtain wall with sky-blue mullions behind a balcony (escalators arrive in the
    railing gap x 10.5..20.5), a candy scalloped valance under the balcony, roof parapet and the
    big lettered "NUKE MEGASTORE" roof sign.
    """
    m = Model("A8_Storefront", STORE_PIVOT, budget=6000)
    walls = m.piece("Walls", WHITE)
    accent = m.piece("Accent", PINK)
    trim = m.piece("Trim", SKY_BLUE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.4)
    floor = m.piece("Floor", CREAM)
    sign = m.piece("Sign", CREAM)
    frame = m.piece("SignFrame", YELLOW)
    counter = m.piece("Counter", MINT)
    belt = m.piece("Checkout", CHARCOAL)  # not "Belt": WorldFx would scroll its studs
    glow = m.piece("RegisterGlow", GLOW_GREEN, material="Neon")  # not "Glow": WorldFx would bob it
    lights = m.piece("Lights", LAMP_WARM, material="Neon")
    letters = m.piece("Letters", PURPLE, material="Smooth")
    hw, hd = SW / 2, SD / 2
    zf = -hd + 0.5  # facade wall centre plane
    box(floor, (0, 0.03, 0), (SW - 1.0, 0.1, SD - 1.0))
    block(accent, (0, 0.06, -hd + 2.5), (12.0, 0.1, 3.0), bevel=0.03)  # entrance mat
    # Shell: side walls, back wall, first-floor slab (+ balcony), roof slab, parapet.
    for s in (-1, 1):
        box(walls, (s * (hw - 0.5), (F2 + 1.0) / 2, 0), (1.0, F2 + 1.0, SD))
        block(accent, (s * (hw + 0.05), F1 + 0.5, 0), (0.3, 1.1, SD + 0.2), bevel=0.06)  # 11.95..13.05: proud
    box(walls, (0, (F2 + 1.0) / 2, hd - 0.5), (SW - 2.0, F2 + 1.0, 1.0))
    slab_d = hd - BALCONY_Z
    box(walls, (0, F1 + 0.5, (hd + BALCONY_Z) / 2), (SW, 1.0, slab_d))
    # Balcony fascia: top 13.05 = proud of the slab (13.0), below the escalator landing plates (13.1).
    block(accent, (0, F1 + 0.475, BALCONY_Z - 0.1), (SW + 0.4, 1.15, 0.4), bevel=0.1)
    box(walls, (0, F2 + 0.5, 0), (SW, 1.0, SD))
    for zs in (-1, 1):
        block(trim, (0, F2 + 1.5, zs * (hd - 0.4)), (SW + 0.4, 1.0, 0.8), bevel=0.15)
    for s in (-1, 1):
        block(trim, (s * (hw - 0.4), F2 + 1.5, 0), (0.8, 1.0, SD), bevel=0.15)
    # Ground-floor facade: pink entrance pillars, display windows, lintel.
    for s in (-1, 1):
        block(accent, (s * (ENTRANCE_HALF + 0.8), F1 / 2, zf - 0.2), (1.6, F1, 1.6), bevel=0.25)
        x0, x1 = ENTRANCE_HALF + 1.6, hw - 1.0
        cx = s * (x0 + x1) / 2
        box(walls, (cx, 0.6, zf), (x1 - x0, 1.2, 1.0))
        box(walls, (cx, (9.4 + F1) / 2, zf), (x1 - x0, F1 - 9.4, 1.0))
        box(glass, (cx, 5.3, zf), (x1 - x0 + 0.2, 8.4, 0.2))  # edges 0.1 inside walls / pillars (R18)
        block(trim, (cx, 1.3, zf - 0.3), (x1 - x0 + 0.4, 0.3, 1.2), bevel=0.06)
        block(trim, (cx, 5.3, zf), (0.35, 8.2, 0.5), bevel=0.05)
        # A pyramid of boxed nukes in each display window.
        for row, count in enumerate((4, 3, 2)):
            for k in range(count):
                bx = cx + (k - (count - 1) / 2) * 1.7
                piece = counter if (k + row) % 2 == 0 else accent
                box(piece, (bx, 1.9 + row * 1.5, zf + 1.2), (1.4, 1.4, 1.0))  # behind glass: no bevel
    block(accent, (0, F1 - 0.75, zf - 0.2), (2 * ENTRANCE_HALF + 3.2, 1.5, 1.6), bevel=0.2)  # lintel
    # First-floor curtain wall: glass + mullions + transom + top band.
    box(glass, (0, (F1 + 1.0 + 21.6) / 2, zf), (SW - 2.0, 21.6 - F1 - 1.0 + 0.2, 0.2))  # into slab + band
    for i in range(11):
        x = -hw + 1.0 + i * (SW - 2.0) / 10
        block(trim, (x, (F1 + 1.0 + 21.6) / 2, zf), (0.5, 21.6 - F1 - 1.0, 0.8), bevel=0.08)
    block(trim, (0, 17.3, zf), (SW - 2.0, 0.4, 0.8), bevel=0.08)
    box(walls, (0, (21.6 + F2) / 2, zf), (SW - 2.0, F2 - 21.6, 1.0))
    # Balcony railing (white posts + rail, glass infill) with the escalator gap.
    rail_z = BALCONY_Z + 0.3
    for x0, x1 in ((-hw + 0.2, ESC_GAP[0]), (ESC_GAP[1], hw - 0.2)):
        n = max(1, int(round((x1 - x0) / 3.0)))
        for k in range(n + 1):
            x = x0 + (x1 - x0) * k / n
            bar(walls, (x, F1 + 1.0, rail_z), (x, F1 + 2.4, rail_z), 0.22)
        bar(walls, (x0, F1 + 2.45, rail_z), (x1, F1 + 2.45, rail_z), 0.26)
        box(glass, ((x0 + x1) / 2, F1 + 1.7, rail_z), (x1 - x0, 1.2, 0.08))
    for s in (-1, 1):
        bar(walls, (s * (hw - 0.2), F1 + 2.45, rail_z), (s * (hw - 0.2), F1 + 2.45, -hd), 0.26)
        bar(walls, (s * (hw - 0.2), F1 + 1.0, (rail_z - hd) / 2), (s * (hw - 0.2), F1 + 2.4, (rail_z - hd) / 2), 0.22)
    # Candy scalloped valance under the balcony front (alternating pink/white with half-disc tabs).
    tabs = 24
    for k in range(tabs):
        x = -hw + SW * (k + 0.5) / tabs
        piece = accent if k % 2 == 0 else walls
        box(piece, (x, F1 - 0.45, BALCONY_Z - 0.25), (SW / tabs, 0.9, 0.3))
        half = [(x + 0.95 * math.cos(math.pi * t / 6), F1 - 0.9 - 0.7 * math.sin(math.pi * t / 6), BALCONY_Z - 0.25) for t in range(7)]
        prism(piece, half, (0, 0, 1), 0.3)
    # Lettered roof sign on the parapet.
    sign_c, sign_size = (0, F2 + 4.6, -hd + 0.2), (30.0, 5.2)
    sign_frame(frame, sign, sign_c, sign_size, border=0.7, depth=0.9)
    sign_text(letters, "NUKE MEGASTORE", sign_c, sign_size, 0.7, 0.9, letter_depth=0.3)
    for s in (-1, 1):
        block(trim, (s * 10.0, F2 + 3.0, -hd + 1.4), (0.8, 4.0, 0.8), bevel=0.1)  # sign braces
    # Checkout counters (the producer): three counters across the entrance, lanes between them.
    for cx in (-9.0, 0.0, 9.0):
        block(counter, (cx, 1.5, -6.0), (6.0, 3.0, 2.2), bevel=0.2)
        block(walls, (cx, 3.15, -6.0), (6.3, 0.3, 2.5), bevel=0.08)
        box(belt, (cx - 0.8, 3.36, -6.0), (4.0, 0.12, 1.4))
        block(belt, (cx + 2.2, 3.85, -6.1), (1.3, 1.0, 1.1), bevel=0.12)  # register
        box(glow, (cx + 2.2, 4.15, -6.67), (0.9, 0.4, 0.06))
        bar(trim, (cx - 2.9, 3.3, -6.9), (cx - 2.9, 6.6, -6.9), 0.2)  # lane light pole
        block(lights, (cx - 2.9, 7.0, -6.9), (0.9, 0.8, 0.9), bevel=0.12)
    # Ceiling light panels under the first-floor slab.
    for x in (-15.0, -5.0, 5.0, 15.0):
        for z in (-3.0, 6.0):
            box(lights, (x, F1 - 0.08, z), (6.0, 0.15, 1.2))
    return m


def build_shelves():
    """
    Four double-sided gondola shelves inside the store (two rows, centre aisle), stocked on both
    faces with boxed toy nukes in four candy colours (two box heights for a lively skyline), a
    white price strip along every shelf edge, plus two hanging yellow SALE boards with a pink star.
    Store-origin pivot. Mobile budget (owner R11): one strip per shelf side instead of a label
    per box keeps the whole stock at ~2.9k triangles.
    """
    m = Model("A8_Shelves", STORE_PIVOT, budget=6000)
    shelf = m.piece("Shelf", WHITE)
    panel = m.piece("Panel", SKY_BLUE)
    colours = [
        m.piece("BoxRed", TOY_RED, material="StudsSmall"),
        m.piece("BoxMint", MINT, material="StudsSmall"),
        m.piece("BoxYellow", YELLOW, material="StudsSmall"),
        m.piece("BoxPurple", PURPLE, material="StudsSmall"),
    ]
    band = m.piece("Band", WHITE, material="Smooth")
    pink = m.piece("Pink", PINK)
    for gz in (1.5, 7.5):
        for gx in (-9.5, 9.5):
            length = 15.0
            block(shelf, (gx, 0.3, gz), (length, 0.6, 2.6), bevel=0.1)
            # Panel ends at +-7.25: inside the end posts (7.2..7.5), clear of the board ends (7.3) (R18).
            block(panel, (gx, 3.5, gz), (length - 0.5, 6.0, 0.3), bevel=0.08)
            for s in (-1, 1):
                block(shelf, (gx + s * (length / 2 - 0.15), 3.3, gz), (0.3, 6.6, 2.6), bevel=0.06)
            for lvl, y in enumerate((0.6, 2.2, 3.8)):
                box(shelf, (gx, y + 0.1, gz), (length - 0.4, 0.2, 2.5))
                for side in (-1, 1):
                    for k in range(7):
                        bx = gx - length / 2 + 1.2 + k * 2.1
                        bz = gz + side * 0.72
                        piece = colours[(k + lvl + (1 if side > 0 else 0) + (2 if gx > 0 else 0)) % 4]
                        h = 1.3 if (k + lvl) % 3 else 1.05
                        box(piece, (bx, y + 0.2 + h / 2, bz), (1.5, h, 1.0))
                    box(band, (gx, y + 0.12, gz + side * 1.28), (length - 0.4, 0.34, 0.06))
            block(shelf, (gx, 6.65, gz), (length, 0.3, 2.6), bevel=0.08)
    # Hanging SALE boards over the aisle (rods from the ceiling).
    for z in (1.5, 7.5):
        for s in (-1, 1):
            bar(shelf, (s * 2.2, F1, z), (s * 2.2, 10.2, z), 0.12)
        block(colours[2], (0, 9.4, z), (5.6, 1.8, 0.25), bevel=0.06)
        _star(pink, (0, 9.4, z - 0.2), 0.75, 0.35, 0.12)
    return m


# ------------------------------------------------------------------------------------------------
# Escalators
# ------------------------------------------------------------------------------------------------


def build_escalators():
    """
    Twin escalators (two 4.4-wide lanes) from the plaza up to the store balcony: white truss body,
    20 charcoal steps per lane with yellow edge lines, glass balustrades with black handrails and a
    glowing skirt strip, steel landing plates and a white support column. Store-origin pivot.
    The walking incline runs from (z -35, y 0.3) to (z -17.5, y 13): ~36 deg.
    """
    m = Model("A8_Escalators", STORE_PIVOT + "; lanes at x 13 / 18, bottom landing z -38, top on the balcony", budget=5000)
    body = m.piece("Body", WHITE)
    steps = m.piece("Steps", CHARCOAL)
    edges = m.piece("Edges", YELLOW, material="Smooth")
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    glow = m.piece("SkirtLight", SKY_BLUE, material="Neon")  # not "Glow": WorldFx would bob it
    plates = m.piece("Plates", STEEL)
    (z0, y0), (z1, y1) = ESC_BOTTOM, ESC_TOP
    dz, dy = z1 - z0, y1 - y0
    n_steps = 20
    # The truss runs 0.12 past the first / last step along the incline, so its end caps never sit
    # flush with the step end faces (owner R18 z-fight rule).
    ext = 0.12
    za_t, ya_t = z0 - ext, y0 - ext * dy / dz
    zb_t, yb_t = z1 + ext, y1 + ext * dy / dz
    for cx in ESC_LANES:
        # Truss body under the steps (parallelogram prism along X), clipped at the plaza top (y 0)
        # so its low end rests ON the plaza instead of sinking 0.7 into it (R24 overlap check).
        incline = [(za_t, ya_t - 0.25), (zb_t, yb_t - 0.25), (zb_t, yb_t - 2.1), (za_t, ya_t - 2.1)]
        above = clip_convex(incline, [(-1e3, 0.0), (1e3, 0.0), (1e3, 1e3), (-1e3, 1e3)])
        prism(body, [(cx, y, z) for z, y in above], (1, 0, 0), ESC_W)
        # Steps + yellow edge lines.
        for i in range(n_steps):
            t0, t1 = i / n_steps, (i + 1) / n_steps
            za, zb = z0 + dz * t0, z0 + dz * t1
            top = y0 + dy * t1
            bottom = y0 + dy * t0 - 0.3
            box(steps, (cx, (top + bottom) / 2, (za + zb) / 2), (ESC_W - 0.9, top - bottom, zb - za))
            box(edges, (cx, top + 0.03, za + 0.1), (ESC_W - 0.9, 0.06, 0.18))
        # Balustrades: glass incline + level newel ends, handrail on top, glowing skirt.
        for s in (-1, 1):
            x = cx + s * (ESC_W / 2 - 0.25)
            prism(glass, [(x, y0 + 0.1, z0), (x, y1 + 0.1, z1), (x, y1 + 2.6, z1), (x, y0 + 2.6, z0)], (1, 0, 0), 0.16)
            # Level newel panels stop 0.1 short of the hand-rail end caps (R18).
            box(glass, (x, y0 + 1.35, z0 - 1.2), (0.16, 2.5, 2.4))
            box(glass, (x, y1 + 1.35, z1 + 0.95), (0.16, 2.5, 1.9))
            rail = [(x, y0 + 2.7, z0 - 2.5), (x, y0 + 2.7, z0), (x, y1 + 2.7, z1), (x, y1 + 2.7, z1 + 2.0)]
            for a, b in zip(rail, rail[1:]):
                cylinder(steps, a, b, 0.2, segments=8)
            for p in (rail[0], rail[-1]):
                ellipsoid(steps, p, (0.22, 0.22, 0.22), rings=4, segments=8)
            xi = cx + s * (ESC_W / 2 - 0.45)
            bar(glow, (xi, y0 + 0.35, z0), (xi, y1 + 0.35, z1), 0.12)
            # Side cladding strip on the outer face of the truss (white, slightly proud).
            xo = cx + s * (ESC_W / 2 + 0.05)
            prism(body, [(xo, ya_t - 0.2, za_t), (xo, yb_t - 0.2, zb_t), (xo, yb_t - 1.0, zb_t), (xo, ya_t - 1.0, za_t)], (1, 0, 0), 0.12)
        # Landing plates (bottom on the plaza, top on the balcony).
        box(plates, (cx, y0 / 2, z0 - 1.5), (ESC_W - 0.4, y0 + 0.1, 3.0))
        box(plates, (cx, y1 + 0.05, z1 + 1.0), (ESC_W - 0.4, 0.1, 2.0))
    # One chunky white column under the upper third (between the lanes).
    mid_x = (ESC_LANES[0] + ESC_LANES[1]) / 2
    col_z = -21.0
    col_top = y0 + dy * (col_z - z0) / dz - 2.1
    block(body, (mid_x, col_top / 2, col_z), (1.8, col_top, 1.8), bevel=0.2)
    return m


# ------------------------------------------------------------------------------------------------
# Mascot "Nukey"
# ------------------------------------------------------------------------------------------------


def build_mascot_nukey():
    """
    Giant friendly mascot statue: a chubby yellow cartoon nuke with big shiny eyes, rosy cheeks
    and a wide smile, waving one white-gloved hand and carrying a pink shopping bag, blue fin
    feet, red nose cone, glowing green belt and a plain trefoil belly badge; on a white pedestal
    with a pink band and a lettered "NUKEY" plaque.
    """
    m = Model("A8_MascotNukey", "ground centre of the pedestal (plaza top); Nukey faces -Z; tip at y = 21", budget=6000)
    body = m.piece("Body", YELLOW)
    nose = m.piece("Nose", TOY_RED)
    fins = m.piece("Fins", DEEP_BLUE)
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    white = m.piece("White", WHITE)
    pink = m.piece("Pink", PINK)
    eyes = m.piece("Eyes", WHITE, material="Smooth")
    dark = m.piece("Dark", CHARCOAL, material="Smooth")
    sign = m.piece("Sign", CREAM)
    r = 3.8
    # Pedestal + pink band + plaque.
    revolve(white, [(0.0, 0.0), (7.0, 0.0), (7.2, 0.3), (7.2, 2.5), (6.8, 3.0), (0.0, 3.0)], segments=28)
    revolve(pink, [(7.15, 1.2), (7.35, 1.25), (7.35, 1.85), (7.15, 1.9)], segments=28, closed=True)
    block(sign, (0, 1.55, -6.9), (6.0, 1.4, 1.0), bevel=0.12)
    cell = min(5.2 / text_cells("NUKEY"), 1.0 / FONT_ROWS)
    block_text(dark, "NUKEY", (0, 1.55, -7.4), cell, 0.12, bevel=0.0)
    # Body (nuke shape) standing on its fin feet.
    nuke_body(body, nose, fins, core, base=(0, 3.0, 0), length=18.0, radius=r, fin_count=4, segments=24)

    def surface_z(x):
        """Front (-Z) surface of the round body at horizontal offset x."""
        return -math.sqrt(max(r * r - x * x, 0.01))

    # Eyes: white bulges, dark pupils looking slightly inward, white highlights.
    for s in (-1, 1):
        ex = s * 1.45
        ez = surface_z(ex) + 0.12
        ellipsoid(eyes, (ex, 13.6, ez), (1.05, 1.45, 0.6), rings=8, segments=14)
        ellipsoid(dark, (s * 1.3, 13.4, ez - 0.5), (0.55, 0.78, 0.3), rings=6, segments=12)
        ellipsoid(eyes, (s * 1.3 + 0.22, 13.78, ez - 0.78), (0.22, 0.26, 0.12), rings=4, segments=8)
        bar(dark, (s * 0.65, 15.3, surface_z(0.65) - 0.08), (s * 2.25, 15.6, surface_z(2.25) - 0.08), 0.26)  # brow
        ellipsoid(pink, (s * 2.55, 12.0, surface_z(2.55) + 0.05), (0.75, 0.48, 0.3), rings=5, segments=10)
    # Smile: chunky curved line hugging the body front.
    pts = []
    for i in range(9):
        t = -1.0 + i * 0.25
        x = 1.35 * t
        pts.append((x, 11.25 + 0.45 * t * t, surface_z(x) - 0.06))
    for a, b in zip(pts, pts[1:]):
        bar(dark, a, b, 0.34)
    # Belly badge (white disc, black trefoil) under the glowing belt.
    revolve(eyes, [(0.0, -0.35), (1.35, -0.35), (1.35, 0.35), (0.0, 0.35)], center=(0, 7.0, surface_z(0) + 0.27), segments=18, rot=rot_x(90))
    trefoil(dark, (0, 7.0, surface_z(0) - 0.12), 1.1, 0.08, normal=(0, 0, -1))
    # Waving arm (+X): upper arm, elbow, forearm, white cuff + glove with thumb.
    shoulder_r, elbow_r = (3.5, 12.4, 0.0), (6.0, 14.0, -0.5)
    wrist_r = (6.6, 17.2, -0.9)
    cylinder(body, shoulder_r, elbow_r, 0.8, segments=12)
    ellipsoid(body, elbow_r, (0.82, 0.82, 0.82), rings=5, segments=10)
    cylinder(body, elbow_r, wrist_r, 0.72, segments=12)
    d = (Vector(wrist_r) - Vector(elbow_r)).normalized()
    w = Vector(wrist_r)
    cylinder(white, tuple(w - d * 0.2), tuple(w + d * 0.5), 0.95, segments=12)
    glove = w + d * 1.45
    ellipsoid(white, tuple(glove), (1.15, 1.3, 0.85), rings=6, segments=12)
    ellipsoid(white, (glove.x - 0.95, glove.y - 0.2, glove.z - 0.2), (0.4, 0.55, 0.4), rings=4, segments=8)
    # Bag arm (-X): arm down-forward, glove holding the shopping bag handles.
    shoulder_l, elbow_l, wrist_l = (-3.5, 12.4, 0.0), (-5.6, 10.6, -0.7), (-6.0, 8.6, -1.5)
    cylinder(body, shoulder_l, elbow_l, 0.8, segments=12)
    ellipsoid(body, elbow_l, (0.82, 0.82, 0.82), rings=5, segments=10)
    cylinder(body, elbow_l, wrist_l, 0.72, segments=12)
    cylinder(white, (-5.97, 8.75, -1.44), (-6.07, 8.2, -1.66), 0.95, segments=12)
    ellipsoid(white, (-6.1, 7.55, -1.7), (1.1, 1.2, 0.85), rings=6, segments=12)
    block(pink, (-6.1, 4.9, -1.9), (2.8, 3.2, 1.4), bevel=0.15)
    for dx in (-0.6, 0.6):
        bar(dark, (-6.1 + dx, 6.5, -1.9), (-6.1 + dx * 0.4, 7.4, -1.75), 0.14)
    _front_disc(body, (-6.1, 5.0, -2.65), 0.8, 0.14)
    return m


# ------------------------------------------------------------------------------------------------
# Billboard (rooftop)
# ------------------------------------------------------------------------------------------------


def build_billboard():
    """
    Giant rooftop billboard on the store roof (store-origin pivot): steel legs and braces, a
    catwalk with yellow railing and three spotlights, the yellow-framed ad board (panel piece Sign),
    a big candy nuke picture on the left with a pink/yellow starburst, brick-letter "GLOWING
    DEALS!" copy beside it and warm marquee bulbs along the top edge.
    """
    m = Model("A8_Billboard", STORE_PIVOT + "; stands on the store roof (y 23); board y 30..44 faces -Z", budget=5000)
    legs = m.piece("Legs", DARK_STEEL)
    steel = m.piece("Steel", STEEL)
    frame = m.piece("Frame", YELLOW)
    sign = m.piece("Sign", CREAM)
    red = m.piece("Red", TOY_RED)
    white = m.piece("White", WHITE)
    dark = m.piece("Dark", CHARCOAL)
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    pink = m.piece("Pink", PINK)
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    letters = m.piece("Letters", PURPLE, material="Smooth")
    roof = F2 + 1.0
    bz = 4.4  # board face plane (local z)
    for x in (-12.0, 0.0, 12.0):
        block(legs, (x, (roof + 30.0) / 2, bz + 0.9), (1.0, 30.0 - roof, 1.0), bevel=0.12)
        bar(legs, (x, roof, bz + 5.0), (x, 29.0, bz + 1.1), 0.6)
        block(legs, (x, roof + 0.2, bz + 3.0), (1.6, 0.4, 5.0), bevel=0.08)  # foot plate
    # Catwalk + railing + spotlights.
    box(steel, (0, 29.6, bz - 1.2), (37.0, 0.4, 2.6))
    for k in range(10):
        x = -18.4 + k * (36.8 / 9)
        bar(frame, (x, 29.8, bz - 2.4), (x, 30.9, bz - 2.4), 0.16)
    bar(frame, (-18.4, 30.95, bz - 2.4), (18.4, 30.95, bz - 2.4), 0.18)
    for x in (-12.0, 0.0, 12.0):
        block(dark, (x, 30.25, bz - 1.4), (1.0, 0.9, 1.0), bevel=0.15, rot=rot_x(35))
        _front_disc(bulbs, (x, 30.5, bz - 1.85), 0.38, 0.1, segments=10)
    # Board: back plate, yellow frame, Sign panel.
    block(legs, (0, 37.0, bz + 0.65), (36.8, 14.8, 0.6), bevel=0.12)
    sign_frame(frame, sign, (0, 37.0, bz), (36.0, 14.0), border=0.8, depth=0.8)
    # Ad art: candy nuke (half sunk into the board, -X = the viewer's right) with a starburst
    # beside its nose; brick-letter ad copy on the +X side (the viewer's left), read left to right.
    nuke_body(red, white, dark, core, base=(-11.0, 31.2, bz - 1.8), length=11.0, radius=2.0, segments=16)
    _star(frame, (-3.6, 41.0, bz - 0.45), 2.4, 1.6, 0.3, points=12)
    _front_disc(pink, (-3.6, 41.0, bz - 0.65), 1.45, 0.2, segments=18)
    sign_text(letters, ["GLOWING", "DEALS!"], (7.9, 37.0, bz), (18.6, 11.6), 0.0, 0.8, letter_depth=0.3, pad=0.2)
    # Marquee bulbs along the top edge.
    for k in range(13):
        ellipsoid(bulbs, (-17.4 + k * 2.9, 44.25, bz - 0.25), (0.32, 0.32, 0.32), rings=4, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# Food court
# ------------------------------------------------------------------------------------------------


def _torus(piece, center, major, minor, ring_segments=16, tube_segments=8, front_shift=0.0):
    """Upright torus facing -Z (axis along Z). front_shift moves it toward -Z (frosting layer)."""
    profile = [
        (major + minor * math.cos(2 * math.pi * k / tube_segments), minor * math.sin(2 * math.pi * k / tube_segments))
        for k in range(tube_segments)
    ]
    cx, cy, cz = center
    revolve(piece, profile, center=(cx, cy, cz - front_shift), segments=ring_segments, closed=True, rot=rot_x(90))


def build_food_court():
    """
    "Glow Bites" food court: sky-blue kiosk with a serving window, candy awning, menu sign (piece
    Sign), a giant frosted donut with sprinkles on the roof, four umbrella tables with yellow
    stools, a mint trash bin. Kiosk at the back (+Z), seating in front.
    """
    m = Model("A8_FoodCourt", "ground centre (plaza top); 24 x 26 footprint; kiosk at the back, serves toward -Z", budget=6000)
    kiosk = m.piece("Kiosk", SKY_BLUE)
    white = m.piece("White", WHITE)
    pink = m.piece("Pink", PINK)
    mint = m.piece("Mint", MINT)
    yellow = m.piece("Yellow", YELLOW)
    dough = m.piece("Dough", WOOD)
    steel = m.piece("Steel", STEEL)
    sign = m.piece("Sign", CREAM)
    dark = m.piece("Dark", CHARCOAL)
    glow = m.piece("MenuGlow", LAMP_WARM, material="Neon")  # not "Glow": WorldFx would bob it
    letters = m.piece("Letters", PURPLE, material="Smooth")
    kz0, kz1 = 7.5, 12.5  # kiosk front / back (local z)
    # Kiosk shell: back wall, sides, counter front under the window, header, roof.
    box(kiosk, (0, 4.0, kz1 - 0.5), (18.0, 8.0, 1.0))
    for s in (-1, 1):
        box(kiosk, (s * 8.5, 4.0, (kz0 + kz1) / 2), (1.0, 8.0, kz1 - kz0))
        box(kiosk, (s * 7.75, 5.2, kz0 + 0.5), (0.5, 3.6, 1.0))
    box(kiosk, (0, 1.7, kz0 + 0.5), (18.0, 3.4, 1.0))
    box(kiosk, (0, 7.5, kz0 + 0.5), (18.0, 1.0, 1.0))
    block(white, (0, 8.4, (kz0 + kz1) / 2), (18.8, 0.8, kz1 - kz0 + 0.8), bevel=0.15)
    block(white, (0, 3.55, kz0 + 0.2), (17.0, 0.3, 1.8), bevel=0.08)  # counter top
    # Inside: register, fryer, glowing menu panels on the back wall.
    block(dark, (-5.0, 4.2, kz0 + 0.6), (1.4, 1.0, 1.0), bevel=0.12)
    block(steel, (3.5, 2.0, kz1 - 2.0), (4.0, 4.0, 1.8), bevel=0.15)
    for x in (-5.0, 0.0, 5.0):
        box(glow, (x, 5.6, kz1 - 1.05), (3.6, 2.0, 0.1))
    # Candy awning over the window (9 alternating stripes, sloping toward -Z).
    for k in range(9):
        x = -8.0 + k * 2.0
        block(pink if k % 2 == 0 else white, (x, 7.1, kz0 - 1.35), (2.0, 0.25, 2.9), bevel=0.05, rot=rot_x(-20))
    # Menu sign on the roof front.
    sign_c, sign_size = (0, 10.4, kz0 + 0.3), (14.0, 3.0)
    sign_frame(pink, sign, sign_c, sign_size, border=0.4, depth=0.5)
    sign_text(letters, "GLOW BITES", sign_c, sign_size, 0.4, 0.5, letter_depth=0.2, pad=0.2)
    # Giant donut on a post behind the sign: dough torus, pink frosting layer, sprinkles.
    dc = (0.0, 16.2, kz0 + 3.0)
    cylinder(steel, (0, 8.8, dc[2]), (0, dc[1] - 3.2 - 0.8, dc[2]), 0.45, segments=10)
    _torus(dough, dc, 3.2, 1.3)
    _torus(pink, dc, 3.2, 1.25, front_shift=0.32)
    sprinkle_pieces = (yellow, mint, white, kiosk)
    for k in range(16):
        a = 2 * math.pi * k / 16 + 0.3
        rad = 3.2 + 0.55 * math.sin(3.1 * k)
        cx, cy = dc[0] + rad * math.cos(a), dc[1] + rad * math.sin(a)
        ang = 1.7 * k
        dx, dy = 0.3 * math.cos(ang), 0.3 * math.sin(ang)
        # Sit each sprinkle on the frosting surface: tube centre is 0.32 in front of the dough's.
        sz = dc[2] - 0.32 - math.sqrt(max(1.25 ** 2 - (rad - 3.2) ** 2, 0.0)) - 0.02
        bar(sprinkle_pieces[k % 4], (cx - dx, cy - dy, sz), (cx + dx, cy + dy, sz), 0.16)
    # Four umbrella tables with four yellow stools each.
    for i, (tx, tz) in enumerate(((-6.2, -6.5), (6.2, -6.5), (-6.2, 0.8), (6.2, 0.8))):
        disc(steel, (tx, 0, tz), 0.9, 0.2, segments=12, bevel=0.06)
        cylinder(steel, (tx, 0.2, tz), (tx, 2.6, tz), 0.16, segments=8)
        disc(white, (tx, 2.6, tz), 1.9, 0.25, segments=12, bevel=0.08)
        cylinder(steel, (tx, 2.85, tz), (tx, 7.8, tz), 0.1, segments=6)
        cylinder(pink if i % 2 == 0 else mint, (tx, 6.3, tz), (tx, 7.6, tz), 3.2, segments=12, radius_b=0.25)
        ellipsoid(white, (tx, 7.85, tz), (0.22, 0.22, 0.22), rings=4, segments=8)
        for k in range(4):
            a = math.pi / 4 + k * math.pi / 2
            sx, sz = tx + 2.9 * math.cos(a), tz + 2.9 * math.sin(a)
            cylinder(steel, (sx, 0, sz), (sx, 1.6, sz), 0.13, segments=5)
            cylinder(yellow, (sx, 1.55, sz), (sx, 1.85, sz), 0.65, segments=8)  # 16 stools: keep them cheap
    # Mint trash bin with a lid.
    cylinder(mint, (10.4, 0, 5.2), (10.4, 2.4, 5.2), 0.8, segments=12)
    disc(white, (10.4, 2.4, 5.2), 0.9, 0.3, segments=12, bevel=0.08)
    return m


# ------------------------------------------------------------------------------------------------
# Parking garage
# ------------------------------------------------------------------------------------------------

GW, GD = 24.0, 48.0  # garage footprint (x -12..12, z -24..24)
L1_TOP, ROOF_TOP = 6.8, 13.8  # parking deck tops (slabs 0.8 thick)
RAMP_A_X = (-10.6, -5.0)  # ground -> L1 lane (rises toward +Z, z 2 -> 22)
RAMP_B_X = (5.0, 10.6)  # L1 -> roof lane (rises toward -Z, z 22 -> 2)
RAMP_Z = (2.0, 22.0)


def _toy_car(body, glass, wheels, lights, center, yaw):
    """
    Chunky cartoon toy car (7 long, 3.8 wide): rounded body, glass cabin with a body-colour roof,
    four fat wheels, warm headlights. `center` = ground centre; yaw (deg) turns the car's nose
    from -Z. Every part is transformed so the car can face any direction.
    """
    rot = rot_y(yaw)
    cx, cy, cz = center

    def at(x, y, z):
        v = rot @ Vector((x, y, z))
        return (cx + v.x, cy + v.y, cz + v.z)

    block(body, at(0, 1.35, 0), (3.8, 1.5, 7.0), bevel=0.45, rot=rot)
    box(glass, at(0, 2.65, 0.4), (3.5, 1.1, 3.9), rot=rot)
    block(body, at(0, 3.35, 0.4), (3.6, 0.35, 4.0), bevel=0.12, rot=rot)
    for sx in (-1, 1):
        for sz in (-1, 1):
            cylinder(wheels, at(sx * 1.75, 0.85, sz * 2.3), at(sx * 2.15, 0.85, sz * 2.3), 0.85, segments=8)
        block(lights, at(sx * 1.2, 1.45, -3.48), (0.8, 0.45, 0.1), bevel=0.04, rot=rot)


BARRIER_HINGE = (-4.3, 2.4, -22.8)  # garage-local ticket-barrier hinge (top of the Concrete post)


def build_shopper_car():
    """
    Drivable blue toy car (owner R56): the same chunky _toy_car look (7 long, 3.8 wide, rounded body,
    glass cabin with a body-colour roof, warm headlights) built at yaw 0, nose toward -Z, so the
    client can drive it out of A8_ParkingGarage (its old spot: garage-local (6.8, 0.08, -7.0), yaw 90).

    Pieces: Body (DEEP_BLUE), Glass, Headlights (Neon, small), BrakeLights (Smooth; client -> Neon
    when braking), IndicatorL / IndicatorR (amber, under each head / brake light), TyresF (z -2.3)
    / TyresR (z 2.3), r 0.85 at x +-1.95, with spoked HubsF / HubsR (bbox centre = axle point).
    """
    m = Model(
        "A8_ShopperCar",
        "ground centre; nose -Z (layout yaws it 90 into the garage spot); axles z -2.3 / 2.3, wheel r 0.85",
        budget=2000,
    )
    body = m.piece("Body", DEEP_BLUE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.35)
    lights = m.piece("Headlights", LAMP_WARM, material="Neon")
    brake = m.piece("BrakeLights", TOY_RED, material="Smooth")
    ind_l = m.piece("IndicatorL", AMBER, material="Smooth")
    ind_r = m.piece("IndicatorR", AMBER, material="Smooth")
    # Same body / cabin / roof / headlights as _toy_car(center=(0, 0, 0), yaw=0).
    block(body, (0, 1.35, 0), (3.8, 1.5, 7.0), bevel=0.45)
    box(glass, (0, 2.65, 0.4), (3.5, 1.1, 3.9))
    block(body, (0, 3.35, 0.4), (3.6, 0.35, 4.0), bevel=0.12)
    for sx in (-1, 1):
        block(lights, (sx * 1.2, 1.45, -3.48), (0.8, 0.45, 0.1), bevel=0.04)
        block(brake, (sx * 1.2, 1.45, 3.48), (0.8, 0.45, 0.1), bevel=0.04)
        # Turn signals tucked under the head / brake lamps, on the lower bevel of the nose / tail
        # (box back 0.04+ inside the body there, front ~0.06 proud).
        ind = ind_r if sx > 0 else ind_l
        for zf in (-1, 1):
            block(ind, (sx * 1.2, 0.95, zf * 3.49), (0.6, 0.22, 0.12), bevel=0.03)
    # Wheels: one Tyres + Hubs piece per axle (fatter + rounder than the parked toys' 8-gons).
    for suffix, z in (("F", -2.3), ("R", 2.3)):
        axle_wheels(m.piece("Tyres" + suffix, CHARCOAL), m.piece("Hubs" + suffix, STEEL, material="StudsSmall"), 1.95, z, 0.85, 0.55)
    return m


def _deck_rect(piece, x0, x1, z0, z1, top, thick=0.8):
    """One rectangular parking-deck slab with its top at `top`."""
    box(piece, ((x0 + x1) / 2, top - thick / 2, (z0 + z1) / 2), (x1 - x0, thick, z1 - z0))


def build_parking_garage():
    """
    Open three-level parking garage: ground floor + L1 deck (top 6.8) + roof deck (top 13.8),
    ramp A (ground -> L1, left lane, rising toward the back) and ramp B (L1 -> roof, right lane,
    rising toward the front), parapets with yellow caps, railings along the ramp wells, white
    space lines, five parked candy toy cars, a ticket booth with a hazard barrier arm and a big
    "P" sign (piece Sign) on the roof. Entrance faces -Z.

    R56: the sixth car (blue, ground floor at (6.8, 0.08, -7.0) yaw 90) is now its own drivable
    model A8_ShopperCar, and the barrier arm is two separate pieces BarrierYellow + BarrierBlack,
    authored DOWN (horizontal, from the hinge (-4.3, 2.4, -22.8) toward -X, 3.6 long, 4 stripes)
    so the client can lift it by rotating both pieces about the hinge's Z axis. The hinge post
    stays in Concrete (top y 2.4 = hinge height).
    """
    m = Model("A8_ParkingGarage", "ground centre (plaza top); 24 x 48 footprint; entrance faces -Z", budget=6000)
    concrete = m.piece("Concrete", CONCRETE)
    dark = m.piece("Dark", CONCRETE_DARK)
    edge = m.piece("Edge", HAZARD_YELLOW)
    lines = m.piece("Lines", WHITE, material="Smooth")
    sign = m.piece("Sign", SKY_BLUE)
    red = m.piece("CarRed", TOY_RED)
    lime = m.piece("CarLime", LIME)
    orange = m.piece("CarOrange", ORANGE)
    wheels = m.piece("Wheels", CHARCOAL)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.35)
    lights = m.piece("Lights", LAMP_WARM, material="Neon")
    hw, hd = GW / 2, GD / 2
    box(dark, (0, 0.03, 0), (GW, 0.1, GD))  # ground floor asphalt
    # L1 deck: everything except the ramp-A well (x -12..-5, z 2..22).
    _deck_rect(concrete, -5.0, hw, -hd, hd, L1_TOP)
    _deck_rect(concrete, -hw, -5.0, -hd, RAMP_Z[0], L1_TOP)
    _deck_rect(concrete, -hw, -5.0, RAMP_Z[1], hd, L1_TOP)
    _deck_rect(concrete, -hw, RAMP_A_X[0], RAMP_Z[0], RAMP_Z[1], L1_TOP)  # ledge carrying the side parapet
    # Roof deck: everything except the ramp-B well (x 5..12, z 2..24).
    _deck_rect(concrete, -hw, 5.0, -hd, hd, ROOF_TOP)
    _deck_rect(concrete, 5.0, hw, -hd, RAMP_Z[0], ROOF_TOP)
    # Ramps (sloped slabs, top surface = driving surface) with yellow curbs.
    for (xa, xb), (ya, yb), (za, zb) in (
        (RAMP_A_X, (0.0, L1_TOP), RAMP_Z),
        (RAMP_B_X, (L1_TOP, ROOF_TOP), (RAMP_Z[1], RAMP_Z[0])),
    ):
        cx = (xa + xb) / 2
        # Ramp slab clipped at the garage floor (y 0): ramp A's low end rests on the plaza instead
        # of sinking 0.6 into it (R24 overlap check).
        slab = clip_convex([(za, ya), (zb, yb), (zb, yb - 0.6), (za, ya - 0.6)], [(-1e3, 0.0), (1e3, 0.0), (1e3, 1e3), (-1e3, 1e3)])
        prism(dark, [(cx, y, z) for z, y in slab], (1, 0, 0), xb - xa)
        for x in (xa + 0.15, xb - 0.15):
            bar(edge, (x, ya + 0.2, za), (x, yb + 0.2, zb), 0.3)
        # Hand rail on the open (outer) side of each ramp, posts every ~4 studs.
        xr = xb - 0.15 if xa > 0 else xa + 0.15
        bar(edge, (xr, ya + 1.4, za), (xr, yb + 1.4, zb), 0.18)
        for k in range(6):
            t = k / 5
            bar(edge, (xr, ya + (yb - ya) * t, za + (zb - za) * t), (xr, ya + (yb - ya) * t + 1.4, za + (zb - za) * t), 0.14)
    # Columns: perimeter (x +-11.4) + four at the ramp-well corners.
    col_pts = [(sx * 11.4, z) for sx in (-1, 1) for z in (-23.4, -12.0, 0.0, 12.0, 23.4)]
    # Ramp-well corner columns at x +-4.55: their outer faces (+-5.05) sit 0.05 inside the well
    # railings' faces (+-5.1) instead of sharing them (z-fight audit, R18).
    col_pts += [(-4.55, RAMP_Z[0]), (-4.55, RAMP_Z[1]), (4.55, RAMP_Z[0]), (4.55, RAMP_Z[1])]
    for x, z in col_pts:
        block(concrete, (x, ROOF_TOP / 2, z), (1.0, ROOF_TOP, 1.0), bevel=0.12)
    # Parapets (concrete) with yellow caps: L1 full perimeter; roof perimeter except the ramp well.
    def parapet(x0, x1, z0, z1, top):
        cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
        sx, sz = max(x1 - x0, 0.6), max(z1 - z0, 0.6)
        box(concrete, (cx, top + 0.5, cz), (sx, 1.0, sz))
        block(edge, (cx, top + 1.1, cz), (sx + 0.1, 0.25, sz + 0.1), bevel=0.05)

    for top in (L1_TOP,):
        parapet(-hw, hw, -hd, -hd + 0.6, top)
        parapet(-hw, hw, hd - 0.6, hd, top)
        parapet(-hw, -hw + 0.6, -hd, hd, top)
        parapet(hw - 0.6, hw, -hd, hd, top)
    parapet(-hw, hw, -hd, -hd + 0.6, ROOF_TOP)
    parapet(-hw, 5.0, hd - 0.6, hd, ROOF_TOP)
    parapet(-hw, -hw + 0.6, -hd, hd, ROOF_TOP)
    parapet(hw - 0.6, hw, -hd, RAMP_Z[0], ROOF_TOP)
    # Railings along the ramp wells (yellow bars).
    for (x0, z0, x1, z1, top) in (
        (-5.0, RAMP_Z[0], -5.0, RAMP_Z[1], L1_TOP),
        (-hw + 0.6, RAMP_Z[0], -5.0, RAMP_Z[0], L1_TOP),
        (5.0, RAMP_Z[0], 5.0, hd - 0.6, ROOF_TOP),
    ):
        bar(edge, (x0, top + 1.3, z0), (x1, top + 1.3, z1), 0.2)
        n = max(1, int(math.hypot(x1 - x0, z1 - z0) / 3.0))
        for k in range(n + 1):
            t = k / n
            x, z = x0 + (x1 - x0) * t, z0 + (z1 - z0) * t
            bar(edge, (x, top, z), (x, top + 1.3, z), 0.16)
    # Space lines (L0 right half, L1 left-front, roof left half).
    for (x0, x1, top) in ((2.0, 11.0, 0.0), (-11.0, -5.5, L1_TOP), (-11.0, -2.0, ROOF_TOP)):
        for z in (-22.0, -16.0, -10.0, -4.0):
            box(lines, ((x0 + x1) / 2, top + 0.09, z), (x1 - x0, 0.06, 0.22))
    # Toy cars.
    _toy_car(red, glass, wheels, lights, (6.8, 0.08, -19.0), 90)
    # (6.8, 0.08, -7.0) yaw 90 is A8_ShopperCar's parking spot (R56: own drivable model).
    _toy_car(lime, glass, wheels, lights, (-7.8, L1_TOP, -13.0), -90)
    _toy_car(orange, glass, wheels, lights, (-7.8, L1_TOP, -1.0), -90)
    _toy_car(red, glass, wheels, lights, (-6.5, ROOF_TOP, -13.0), -90)
    _toy_car(lime, glass, wheels, lights, (-6.5, ROOF_TOP, 10.0), 180)
    # Ticket booth + raised hazard barrier at the entrance lane.
    block(red, (-2.6, 1.6, -21.5), (2.2, 3.2, 2.2), bevel=0.2)
    box(glass, (-2.6, 2.3, -22.65), (1.6, 1.0, 0.1))
    block(concrete, (-2.6, 3.4, -21.5), (2.6, 0.4, 2.6), bevel=0.1)
    # Barrier arm (R56): own pieces, authored DOWN along -X from the hinge; the client lifts it
    # (up to ~70 deg, tip y ~5.78, still under the L1 slab bottom y 6.0) by rotating about
    # BARRIER_HINGE's Z axis by a NEGATIVE angle (a +angle about +Z would tip the -X arm down).
    pivot = Vector(BARRIER_HINGE)
    arm_dir = Vector((-1.0, 0.0, 0.0))
    arm_yellow = m.piece("BarrierYellow", HAZARD_YELLOW)
    arm_black = m.piece("BarrierBlack", HAZARD_BLACK)
    block(concrete, (pivot.x, 1.2, pivot.z), (0.7, 2.4, 0.7), bevel=0.1)
    for k in range(4):  # 3.6 long, 4 stripes (yellow at the hinge)
        a = pivot + arm_dir * (k * 0.9)
        b = pivot + arm_dir * ((k + 1) * 0.9)
        bar(arm_yellow if k % 2 == 0 else arm_black, tuple(a), tuple(b), 0.3)
    # "P" sign on the roof's front-right corner: post, sky-blue panel, white P made of blocks.
    block(dark, (9.0, (ROOF_TOP + 19.0) / 2, -22.0), (0.7, 19.0 - ROOF_TOP, 0.7), bevel=0.1)
    block(sign, (9.0, 21.2, -22.2), (4.6, 4.6, 0.5), bevel=0.25)
    # A viewer facing the sign (looking +Z) has -X on their RIGHT, so the stem sits at +X.
    pz = -22.5
    block(lines, (9.9, 21.2, pz), (0.75, 3.4, 0.14), bevel=0.04)
    block(lines, (9.0, 22.55, pz), (1.8, 0.7, 0.14), bevel=0.04)
    block(lines, (9.0, 21.15, pz), (1.8, 0.7, 0.14), bevel=0.04)
    block(lines, (8.15, 21.85, pz), (0.7, 2.0, 0.14), bevel=0.04)
    return m


# ------------------------------------------------------------------------------------------------
# Store Manager (Manager robot)
# ------------------------------------------------------------------------------------------------


def build_store_manager():
    """
    Friendly shopkeeper robot (~7.8 studs) on a rolling base: pink barrel body, white apron panel,
    yellow name badge, red bow tie, white head with happy "^ ^" eyes and a smile on a dark visor,
    a little mint shop cap, relaxed right arm, shopping basket with two boxed nukes on the left.

    Animated NPC (owner R30): split into rig pieces (Torso*/Head*/ArmL*/ArmR*, no legs: it rolls,
    see models/_npc_rig.py) so the client ManagerController can glide it on its base, swing its
    arms, wave (it raises the relaxed right arm) and play its work tap. Rest pose = right arm down;
    the basket rides the left arm (its bone ends at the basket floor so the whole basket follows).
    """
    from models._npc_rig import rig_split

    m = Model("A8_StoreManager", "ground centre (plaza top); faces -Z", budget=2500)
    base = m.piece("Base", CHARCOAL, material="StudsSmall")
    body = m.piece("Body", PINK, material="StudsSmall")
    white = m.piece("White", WHITE, material="StudsSmall")
    visor = m.piece("Visor", DEEP_BLUE, material="Smooth")
    eyes = m.piece("Eyes", CYAN, material="Neon")
    red = m.piece("Red", TOY_RED, material="StudsSmall")
    badge = m.piece("Badge", YELLOW, material="Smooth")
    basket = m.piece("Basket", MINT, material="StudsSmall")
    revolve(base, [(0.0, 0.0), (1.7, 0.0), (1.95, 0.3), (1.75, 0.9), (0.0, 0.9)], segments=18)
    revolve(body, [(0.0, 0.9), (1.5, 0.9), (1.75, 1.5), (1.8, 3.8), (1.6, 4.6), (0.0, 4.7)], segments=18)
    block(white, (0, 2.6, -1.62), (2.2, 2.4, 0.3), bevel=0.12)  # apron
    block(badge, (0.75, 3.95, -1.66), (0.8, 0.45, 0.12), bevel=0.04)
    # Bow tie: two triangles + knot.
    for s in (-1, 1):
        prism(red, [(0, 4.5, -1.62), (s * 0.75, 4.85, -1.62), (s * 0.75, 4.15, -1.62)], (0, 0, 1), 0.22)
    block(red, (0, 4.5, -1.7), (0.3, 0.3, 0.25), bevel=0.06)
    cylinder(base, (0, 4.65, 0), (0, 5.1, 0), 0.5, segments=10)
    block(white, (0, 6.2, 0), (2.8, 2.2, 2.4), bevel=0.6, segments=2)
    block(visor, (0, 6.25, -1.19), (2.2, 1.3, 0.18), bevel=0.25, segments=2)
    for s in (-1, 1):  # happy closed eyes "^ ^"
        bar(eyes, (s * 0.55 - 0.28, 6.4, -1.31), (s * 0.55, 6.68, -1.31), 0.12)
        bar(eyes, (s * 0.55, 6.68, -1.31), (s * 0.55 + 0.28, 6.4, -1.31), 0.12)
    for x0, y0, x1, y1 in ((-0.5, 6.05, -0.18, 5.88), (-0.18, 5.88, 0.18, 5.88), (0.18, 5.88, 0.5, 6.05)):
        bar(eyes, (x0, y0, -1.31), (x1, y1, -1.31), 0.1)
    # Shop cap: crown + brim.
    revolve(basket, [(0.0, 7.25), (1.15, 7.25), (1.1, 7.75), (0.8, 7.95), (0.0, 8.0)], segments=14)
    block(basket, (0, 7.3, -1.2), (1.8, 0.15, 1.0), bevel=0.05)
    # Relaxed right arm (+X), hanging just clear of the barrel (the client raises it to wave).
    cylinder(base, (1.7, 3.9, 0), (2.25, 3.0, -0.2), 0.25, segments=8)
    cylinder(base, (2.25, 3.0, -0.2), (2.35, 2.1, -0.35), 0.22, segments=8)
    ellipsoid(white, (2.4, 1.75, -0.4), (0.45, 0.5, 0.35), rings=5, segments=10)
    # Left arm holding the basket.
    cylinder(base, (-1.7, 3.9, 0), (-2.3, 3.0, -0.7), 0.25, segments=8)
    ellipsoid(white, (-2.35, 2.8, -0.85), (0.42, 0.42, 0.42), rings=5, segments=10)
    bx, by, bz = -2.4, 1.55, -1.35
    box(basket, (bx, by - 0.55, bz), (2.0, 0.12, 1.3))
    for s in (-1, 1):
        box(basket, (bx + s * 0.95, by, bz), (0.12, 1.1, 1.3))
        box(basket, (bx, by, bz + s * 0.6), (2.0, 1.1, 0.12))
    bar(base, (bx - 0.9, by + 0.55, bz), (bx, 2.8, bz + 0.2), 0.08)
    bar(base, (bx, 2.8, bz + 0.2), (bx + 0.9, by + 0.55, bz), 0.08)
    block(red, (bx - 0.4, by + 0.25, bz), (0.7, 0.9, 0.6), bevel=0.06)
    block(badge, (bx + 0.45, by + 0.15, bz), (0.6, 0.75, 0.55), bevel=0.06)
    # Rig skeleton (rolling robot: no legs; base + barrel + neck ride the Torso, pivot on the base).
    bones = {
        "Torso": ((0.0, 0.9, 0.0), (0.0, 4.65, 0.0)),
        "Head": ((0.0, 5.0, 0.0), (0.0, 8.0, 0.0)),
        "ArmL": ((-1.7, 3.9, 0.0), (bx, by - 0.55, bz)),  # ends at the basket floor
        "ArmR": ((1.7, 3.9, 0.0), (2.4, 1.75, -0.4)),
    }
    rig_split(m, bones)
    return m


BUILDERS = {
    "A8_Plaza": build_plaza,
    "A8_EntryArch": build_entry_arch,
    "A8_Storefront": build_storefront,
    "A8_Shelves": build_shelves,
    "A8_Escalators": build_escalators,
    "A8_MascotNukey": build_mascot_nukey,
    "A8_Billboard": build_billboard,
    "A8_FoodCourt": build_food_court,
    "A8_ParkingGarage": build_parking_garage,
    "A8_ShopperCar": build_shopper_car,
    "A8_StoreManager": build_store_manager,
}
