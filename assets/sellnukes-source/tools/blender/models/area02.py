"""
area02.py — Area 2 "Nuke Stand" scene models (B8a): a roadside wooden farm-stand selling candy-
coloured pocket nukes, with a candy-striped awning, a renamable neon "Fresh Nukes!" sign, a retro
fridge, a white picket fence and picnic tables (spec section 3.2).

    A2_Lot          lawn lot + a plank deck the stand sits on + a sandy path from the arch      base
    A2_EntryArch    "NUKE STAND" block-letter arch (barn red posts, chalkboard panel)           base
    A2_Yard         blocky pines, bushes and hay bales                                          base
    A2_StandCounter the producer: planked counter with crates of nukes + a stocked back shelf  A2_Counter
    A2_Awning       red/white striped canopy on four posts with a scalloped valance            A2_Awning
    A2_Register     chunky retro cash register with a pop-up "$" tab                           A2_CashRegister
    A2_TipJar       oversized glass tip jar full of gold coins with a "TIPS" tag               A2_TipJar
    A2_NeonSign     the renamable sign: neon-framed board on posts, nuke mascot on top.         A2_NeonSign
                    Its `Panel` piece front (-Z) face takes the stand-name SurfaceGui
                    (default text "Fresh Nukes!", filtered by the server — B5/B6).
    A2_Fridge       retro glass-door fridge "COLD" stocked with nukes, icy interior glow       A2_Cooler
    A2_FenceRun     16-stud white picket fence run (placed 12x around the lot)                 A2_PicketFence
    A2_CashierBot   the Manager: a hovering mint robot with a smiley screen face and apron     A2_CashierBot
    A2_PicnicTable  table + benches + striped umbrella (placed 4x)                             A2_PicnicTables

Stand-relative models (counter, awning, register, tip jar, cashier bot) share the STAND pivot:
deck-top centre of the stand, customers on the -Z side; the counter top is at y = COUNTER_TOP.
Placement: src/shared/Config/AreaLayouts/Area02.luau. Shared helpers come from models/area01.py.
"""

from __future__ import annotations

import math

from models.area01 import (
    LAWN_LIGHT,
    LOT_TOP,
    SLOT_PIVOT,
    blocky_tree,
    sign_text,
    entry_arch,
    lot_stripes,
    mini_nuke,
    scallops,
    striped_cone,
    tiny_nuke,
    toy_face,
    BARK,
)
from snkit.core import (
    CHARCOAL,
    CREAM,
    DARK_STEEL,
    GLASS,
    GLOW_GREEN,
    GRASS,
    LAMP_WARM,
    LEAF,
    MINT,
    Model,
    ORANGE,
    PINK,
    PURPLE,
    SIDEWALK,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    WHITE,
    WOOD,
    WOOD_DARK,
    YELLOW,
)
from snkit.kit import block
from snkit.shapes import bar, box, cylinder, ellipsoid, prism, revolve, rot_x, rot_z

DECK_TOP = LOT_TOP + 0.3  # plank deck under the stand (walk surface y = 0.8)
COUNTER_TOP = 3.5  # counter top height above the stand pivot
STAND_PIVOT = "stand pivot: deck-top centre of the stand; customers on the -Z side; counter top y = 3.5"
SAND = (236, 214, 160)
HAY = (240, 202, 96)
PLANK_B = (226, 168, 104)
ICE = (190, 236, 255)


# ------------------------------------------------------------------------------------------------
# Base (slot origin pivot)
# ------------------------------------------------------------------------------------------------


def build_lot():
    """Lawn lot with mowed stripes, front curb, a sandy path and the plank deck for the stand."""
    m = Model("A2_Lot", SLOT_PIVOT, budget=1500)
    lawn = m.piece("Lawn", GRASS)
    lawn_light = m.piece("LawnLight", LAWN_LIGHT)
    curb = m.piece("Curb", SIDEWALK)
    plank_a = m.piece("PlanksA", WOOD)
    plank_b = m.piece("PlanksB", PLANK_B)
    sand = m.piece("Path", SAND)
    lot_stripes(lawn, lawn_light, -52, 52, 2.0, 70.0, stripe=8.0)
    block(curb, (0, LOT_TOP / 2 + 0.05, 1.0), (104.0, LOT_TOP + 0.1, 2.0), bevel=0.15)
    # Plank deck: 40 x 20, planks run along X (customers walk across them to the counter).
    for i in range(10):
        z = 22.0 + 2.0 * (i + 0.5)
        block(plank_a if i % 2 == 0 else plank_b, (0, DECK_TOP - 0.15, z), (40.0, 0.3, 2.0), bevel=0.08)
    # Deck skirt so the deck reads as a raised platform.
    block(plank_b, (0, LOT_TOP + 0.05, 32.0), (40.6, 0.3, 20.6), bevel=0.06)
    # Sandy path: arch -> deck front.
    block(sand, (0, LOT_TOP + 0.04, 13.0), (9.0, 0.08, 18.0), bevel=0.04)
    return m


def build_arch():
    """NUKE STAND arch: barn-red posts, white trim, chalkboard-brown panel, sunny yellow letters."""
    return entry_arch(
        "A2_EntryArch",
        "NUKE STAND",
        inner=15.0,
        post_color=TOY_RED,
        trim_color=WHITE,
        panel_color=(96, 70, 52),
        letter_color=YELLOW,
        finial_colors=(PINK, YELLOW),
    )


def build_yard():
    """
    Blocky pines in the back corners, bushes along the deck and hay bales by the stand.

    Trees and hay are split into a -X ("L") and a +X ("R") piece: one piece per colour would have a
    bounding box spanning the whole lot, which the client's producer billboard placement
    (ProducerBillboards.place: Workspace:GetPartBoundsInBox over visible parts, owner R31/R32)
    treats as solid in front of the Nuke Stand (tests/billboard-clearance.luau). +3 pieces.
    """
    m = Model("A2_Yard", SLOT_PIVOT, budget=3000)
    trunks = {-1: m.piece("TrunksL", BARK), 1: m.piece("TrunksR", BARK)}
    leaves = {-1: m.piece("LeavesL", LEAF), 1: m.piece("LeavesR", LEAF)}
    bush = m.piece("Bushes", (58, 168, 66))
    hays = {-1: m.piece("HayL", HAY), 1: m.piece("HayR", HAY)}
    straw = m.piece("Straw", (200, 156, 70), material="StudsSmall")
    for x, z, h, c in ((-44, 62, 11.0, 5.0), (-34, 64, 9.0, 4.2), (44, 62, 11.0, 5.0), (35, 64, 9.5, 4.4), (-45, 22, 9.0, 4.2), (45, 22, 9.0, 4.2)):
        side = -1 if x < 0 else 1
        blocky_tree(trunks[side], leaves[side], (x, LOT_TOP, z), height=h, crown=c)
    for x in (-17.5, -12.0, 12.0, 17.5):
        block(bush, (x, LOT_TOP + 0.9, 20.6), (3.6, 1.8, 1.6), bevel=0.4, segments=2)
    # Hay bales (two stacks) beside the deck, with straw binding bands.
    for x, z, y0 in ((-24.0, 26.0, 0.0), (-24.0, 29.2, 0.0), (-24.0, 27.6, 1.7), (24.0, 38.0, 0.0), (26.6, 38.0, 0.0)):
        hay = hays[-1 if x < 0 else 1]
        block(hay, (x, LOT_TOP + y0 + 0.85, z), (2.4, 1.7, 3.0), bevel=0.25)
        for dz in (-0.75, 0.75):
            block(straw, (x, LOT_TOP + y0 + 0.85, z + dz), (2.5, 1.74, 0.2), bevel=0.04)
    return m


# ------------------------------------------------------------------------------------------------
# Stand (stand pivot)
# ------------------------------------------------------------------------------------------------


def build_counter():
    """
    The Nuke Stand producer: planked wooden counter (16 wide) with two tilted crates of candy
    nukes on its front lip, and a three-shelf back rack stocked with more nukes behind the cashier.
    Free counter-top spots for later purchases: register at (5.4, 3.5, -1.4), tip jar (2.3, 3.5, -1.4).
    """
    m = Model("A2_StandCounter", STAND_PIVOT, budget=3000)
    wood = m.piece("Wood", WOOD)
    dark = m.piece("WoodDark", WOOD_DARK)
    noses = m.piece("NukeNoses", WHITE, material="StudsSmall")
    cores = m.piece("NukeCores", GLOW_GREEN, material="Neon")
    colours = [
        m.piece("NukeRed", TOY_RED, material="StudsSmall"),
        m.piece("NukeMint", MINT, material="StudsSmall"),
        m.piece("NukePurple", PURPLE, material="StudsSmall"),
        m.piece("NukeYellow", YELLOW, material="StudsSmall"),
    ]
    # Counter body: front planks (vertical boards) + dark frame + overhanging top board.
    for i in range(8):
        x = -7.0 + 2.0 * i
        block(wood if i % 2 == 0 else dark, (x, 1.6, -1.25), (2.0, 3.2, 2.5), bevel=0.12)
    block(dark, (0, COUNTER_TOP - 0.15, -1.1), (16.8, 0.3, 3.2), bevel=0.1)
    block(dark, (0, 0.15, -1.25), (16.4, 0.3, 2.7), bevel=0.06)
    # Two tilted display crates on the left half of the counter, four nukes each; the right half
    # stays free for the Cash Register (x = 5.4) and Tip Jar (x = 2.3) purchases.
    for ci, cx in enumerate((-5.6, -1.4)):
        tilt = rot_x(-18)
        block(wood, (cx, COUNTER_TOP + 0.45, -1.9), (4.0, 0.9, 2.0), rot=tilt, bevel=0.12)
        for k in range(4):
            nx = cx - 1.35 + 0.9 * k
            tiny_nuke(colours[(ci + k) % 4], noses, cores, (nx, COUNTER_TOP + 0.55, -1.85 + 0.12 * (k % 2)), height=1.3, radius=0.32)
    # Back rack: two posts, two shelves, a top board, stocked with nukes.
    for sx in (-1, 1):
        block(dark, (sx * 7.2, 3.6, 4.0), (0.6, 7.2, 1.2), bevel=0.1)
    for y in (0.3, 2.6, 4.9):
        block(wood, (0, y, 4.0), (14.6, 0.35, 1.4), bevel=0.08)
    block(dark, (0, 7.3, 4.0), (15.2, 0.4, 1.4), bevel=0.1)
    # Shelf stock is seen from afar: 6-sided, no core band (keeps the counter inside 3,000 tris).
    for y in (0.48, 2.78, 5.08):
        for k in range(9):
            tiny_nuke(colours[(k + int(y)) % 4], noses, None, (-6.4 + 1.6 * k, y, 4.0), height=1.25, radius=0.3, segments=6)
    return m


def build_awning():
    """Candy-striped canopy (red/white bands running front to back) on four white posts."""
    m = Model("A2_Awning", STAND_PIVOT + "; canopy front edge y ~ 8.6", budget=2500)
    red = m.piece("StripesRed", TOY_RED)
    white = m.piece("StripesWhite", WHITE)
    x0, x1 = -9.0, 9.0
    z_front, z_back = -3.9, 5.4
    y_front, y_back = 8.6, 10.4
    for sx in (-1, 1):
        # Front posts reach the low canopy edge, back posts the high edge.
        for z, top in ((-3.2, y_front), (4.8, y_back)):
            block(white, (sx * 8.5, top / 2, z), (0.6, top, 0.6), bevel=0.12)
    # Slanted canopy made of 9 stripes (each a rotated thin box).
    run = z_back - z_front
    rise = y_back - y_front
    length = math.hypot(run, rise)
    # rot_x(-a) lifts a box's +Z end: the canopy rises from the front edge to the back edge.
    angle = -math.degrees(math.atan2(rise, run))
    count = 9
    width = (x1 - x0) / count
    for i in range(count):
        cx = x0 + width * (i + 0.5)
        box(red if i % 2 == 0 else white, (cx, (y_front + y_back) / 2 + 0.15, (z_front + z_back) / 2), (width, 0.3, length + 0.2), rot=rot_x(angle), bevel=0.06)
    # Scalloped valance hanging from the front edge + a white trim bar.
    block(white, (0, y_front + 0.05, z_front - 0.05), (x1 - x0 + 0.3, 0.35, 0.3), bevel=0.08)
    scallops(red, white, x0, x1, y_front - 0.1, z_front - 0.05, size=2.0)
    # Side valances.
    for sx in (-1, 1):
        block(red, (sx * (x1 + 0.05), (y_front + y_back) / 2 - 0.4, (z_front + z_back) / 2), (0.25, 0.8, length), rot=rot_x(angle), bevel=0.06)
    return m


def build_register():
    """Retro cash register (pink body, cream keys facing the customer, pop-up yellow "$" tab)."""
    m = Model("A2_Register", "base centre on the counter top; keys and $ tab face -Z", budget=1500)
    body = m.piece("Body", PINK, material="StudsSmall")
    keys = m.piece("Keys", CREAM, material="Smooth")
    drawer = m.piece("Drawer", STEEL, material="StudsSmall")
    cash = m.piece("Cash", (110, 200, 90), material="Smooth")
    tab = m.piece("Tab", YELLOW, material="Smooth")
    mark = m.piece("Dollar", CHARCOAL, material="Smooth")
    block(drawer, (0, 0.3, 0), (2.8, 0.6, 2.4), bevel=0.08)
    block(cash, (0, 0.36, -1.25), (1.8, 0.12, 0.5), bevel=0.02)
    # Body: tall back block + a keypad wedge sloping down toward the customer (-Z).
    block(body, (0, 1.25, 0.45), (2.6, 1.3, 1.5), bevel=0.2)
    prism(body, [(0, 0.6, -0.3), (0, 0.6, -1.15), (0, 1.0, -1.15), (0, 1.6, -0.3)], (1, 0, 0), 2.6)
    # Keys lie flat on the slope: rows at 25 / 50 / 75 % up the slope, tilted to its angle.
    slope = math.degrees(math.atan2(0.6, 0.85))
    for t in (0.25, 0.5, 0.75):
        for col in range(4):
            y, z = 1.0 + 0.6 * t + 0.08, -1.15 + 0.85 * t - 0.05
            box(keys, (-0.9 + 0.6 * col, y, z), (0.42, 0.16, 0.2), rot=rot_x(-slope))  # crisp keys (R11)
    # Display + pop-up "$" tab.
    block(body, (0, 2.1, 0.5), (1.6, 0.5, 0.9), bevel=0.1)
    bar(drawer, (0, 2.3, 0.5), (0, 2.75, 0.5), 0.12)
    block(tab, (0, 3.15, 0.5), (1.2, 0.85, 0.12), bevel=0.06)
    sign_text(mark, "$", (0, 3.15, 0.5), 0.1, 0.06, 0.06)  # both faces of the tab (R17)
    return m


def build_tip_jar():
    """Oversized glass tip jar: gold coins + green bills inside, steel lid, a wooden TIPS tag."""
    m = Model("A2_TipJar", "base centre on the counter top; tag faces -Z", budget=1500)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.45)
    coins = m.piece("Coins", (255, 200, 40), material="StudsSmall")
    bills = m.piece("Bills", (110, 200, 90), material="Smooth")
    lid = m.piece("Lid", STEEL, material="StudsSmall")
    tag = m.piece("Tag", CREAM, material="Smooth")
    ink = m.piece("Ink", (60, 120, 60), material="Smooth")
    revolve(glass, [(0.0, 0.0), (0.95, 0.0), (1.05, 0.15), (1.05, 2.1), (0.8, 2.4), (0.8, 2.6), (0.0, 2.6)], segments=16)
    # Coin pile: rings of flat 8-sided coins, fewer per ring as the pile narrows (~28 tris each).
    for y, r, n in ((0.2, 0.75, 5), (0.5, 0.68, 5), (0.8, 0.56, 4), (1.1, 0.4, 3)):
        for k in range(n):
            a = 2 * math.pi * k / n + y
            cylinder(coins, (r * math.cos(a) * 0.8, y, r * math.sin(a) * 0.8), (r * math.cos(a) * 0.8, y + 0.14, r * math.sin(a) * 0.8), 0.32, segments=8)
    box(bills, (0.2, 1.5, 0.1), (0.9, 0.06, 0.5), rot=rot_z(25))
    box(bills, (-0.25, 1.65, -0.1), (0.8, 0.06, 0.45), rot=rot_z(-35))
    revolve(lid, [(0.75, 2.55), (0.9, 2.55), (0.9, 2.8), (0.75, 2.8)], segments=16, closed=True)
    # Tag hanging on the jar front, lettered on both faces (R17).
    block(tag, (0, 1.2, -1.12), (1.5, 0.6, 0.08), bevel=0.03)
    sign_text(ink, "TIPS", (0, 1.2, -1.12), 0.075, 0.04, 0.04)
    return m


def build_neon_sign():
    """
    The renamable stand sign (Neon Sign pad): a navy board in a pink + green neon double frame on
    two steel posts, star bulbs at the corners and a glowing pocket-nuke mascot standing on top.
    Double-sided (owner R17): the `Panel` piece is two 15 x 4.2 display faces (front z = -0.3,
    back z = +0.8); B5/B6 mount the filtered stand-name SurfaceGui on both (Area02.standSign).
    """
    m = Model("A2_NeonSign", "ground centre between the posts; panel faces -Z; panel centre y = 15", budget=3000)
    posts = m.piece("Posts", DARK_STEEL)
    panel = m.piece("Panel", (34, 40, 78))
    frame = m.piece("Frame", CHARCOAL)
    pink = m.piece("NeonPink", PINK, material="Neon")
    green = m.piece("NeonGreen", GLOW_GREEN, material="Neon")
    stars = m.piece("Stars", LAMP_WARM, material="Neon")
    cy, w, h = 15.0, 16.0, 5.0
    for sx in (-1, 1):
        block(posts, (sx * 5.5, 0.3, 0.6), (1.8, 0.6, 1.8), bevel=0.12)
        block(posts, (sx * 5.5, (cy - h / 2) / 2 + 0.3, 0.6), (0.8, cy - h / 2, 0.8), bevel=0.12)
        bar(posts, (sx * 5.5, 6.0, 0.6), (sx * 2.5, cy - h / 2 - 0.2, 0.6), 0.4)
    # Double-sided board (owner R17): frame centred on z = 0.25, a display panel, neon tubes and
    # star bulbs on BOTH faces (front -0.25 / back +0.75), so the stand name can show both ways.
    block(frame, (0, cy, 0.25), (w + 0.6, h + 0.6, 0.9), bevel=0.2)
    for face_z, tube_z, star_z in ((-0.25, -0.3, -0.35), (0.75, 0.8, 0.85)):
        box(panel, (0, cy, face_z), (w - 1.0, h - 0.8, 0.1))
        # Neon tubes: pink outer rectangle, green inner rectangle (bars along the frame face).
        for (piece, inset, t) in ((pink, 0.15, 0.22), (green, 0.55, 0.16)):
            x, y = w / 2 - inset, h / 2 - inset
            corners = [(-x, -y), (x, -y), (x, y), (-x, y)]
            for (ax, ay), (bx, by) in zip(corners, corners[1:] + corners[:1]):
                cylinder(piece, (ax, cy + ay, tube_z), (bx, cy + by, tube_z), t, segments=6)
        for sx in (-1, 1):
            for sy in (-1, 1):
                pts = []
                for k in range(10):
                    r = 0.55 if k % 2 == 0 else 0.24
                    a = math.pi / 2 + math.pi * k / 5
                    pts.append((sx * (w / 2 + 0.2) + r * math.cos(a), cy + sy * (h / 2 + 0.2) + r * math.sin(a), star_z))
                prism(stars, pts, (0, 0, 1), 0.18)
    # Mascot nuke on top, standing on a little plinth.
    block(frame, (0, cy + h / 2 + 0.55, 0.25), (2.4, 0.5, 1.6), bevel=0.12)
    body = m.piece("MascotBody", TOY_RED, material="StudsSmall")
    nose = m.piece("MascotNose", WHITE, material="StudsSmall")
    mini_nuke(body, nose, frame, green, (0, cy + h / 2 + 0.8, 0.25), length=3.8, radius=0.95)
    return m


def build_fridge():
    """Retro glass-door fridge (sky blue) stocked with nukes, icy interior light, "COLD" header."""
    m = Model("A2_Fridge", "ground centre; glass door faces -Z", budget=3000)
    body = m.piece("Body", SKY_BLUE)
    trim = m.piece("Trim", WHITE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.5)
    inside = m.piece("Inside", (220, 240, 250), material="Smooth")
    light = m.piece("IceLight", ICE, material="Neon")
    letters = m.piece("Letters", WHITE, material="Smooth")
    shelf = m.piece("Shelves", STEEL, material="StudsSmall")
    noses = m.piece("NukeNoses", WHITE, material="StudsSmall")
    colours = [m.piece("NukeRed", TOY_RED, material="StudsSmall"), m.piece("NukeOrange", ORANGE, material="StudsSmall"), m.piece("NukeMint", MINT, material="StudsSmall")]
    W, H, D = 4.4, 7.4, 3.0
    # Shell: back, sides, top header, base (open front for the glass door).
    block(body, (0, H / 2, D / 2 - 0.3), (W, H, 0.6), bevel=0.2)
    for sx in (-1, 1):
        block(body, (sx * (W / 2 - 0.3), H / 2, 0), (0.6, H, D), bevel=0.2)
    block(body, (0, 0.5, 0), (W, 1.0, D), bevel=0.2)
    block(body, (0, H - 0.75, 0), (W, 1.5, D), bevel=0.25)
    box(inside, (0, H / 2, D / 2 - 0.62), (W - 1.2, H - 2.4, 0.05))
    block(light, (0, H - 1.6, 0.3), (W - 1.4, 0.18, 0.4), bevel=0.04)
    # Header letters on the front AND the back of the fridge (R17) + white feet.
    sign_text(letters, "COLD", (0, H - 0.75, 0), 0.15, 0.08, D / 2)
    for sx in (-1, 1):
        block(trim, (sx * 1.6, 0.05, 0), (0.7, 0.1, D - 0.4), bevel=0.03)
    # Shelves with nukes.
    for si, y in enumerate((1.05, 2.75, 4.45)):
        box(shelf, (0, y, 0.2), (W - 1.2, 0.12, D - 0.8))
        for k in range(4):
            tiny_nuke(colours[(k + si) % 3], noses, None, (-1.2 + 0.8 * k, y + 0.06, 0.2), height=1.2, radius=0.28)
    # Glass door with white frame + chrome handle.
    box(glass, (0, H / 2, -D / 2 + 0.1), (W - 0.9, H - 2.6, 0.12))
    for sy in (-1, 1):
        block(trim, (0, H / 2 + sy * ((H - 2.6) / 2 + 0.15), -D / 2 + 0.05), (W - 0.5, 0.3, 0.3), bevel=0.08)
    for sx in (-1, 1):
        block(trim, (sx * ((W - 0.9) / 2 + 0.1), H / 2, -D / 2 + 0.05), (0.3, H - 2.3, 0.3), bevel=0.08)
    bar(shelf, (1.55, H / 2 - 1.0, -D / 2 - 0.3), (1.55, H / 2 + 1.0, -D / 2 - 0.3), 0.18)
    for sy in (-1, 1):
        bar(shelf, (1.55, H / 2 + sy * 1.0, -D / 2 - 0.3), (1.55, H / 2 + sy * 1.0, -D / 2), 0.14)
    return m


def build_fence_run():
    """16-stud white picket fence run along X: pointed pickets, two back rails, end posts."""
    m = Model("A2_FenceRun", "ground centre of a 16-stud run along X; pickets face -Z", budget=700)
    white = m.piece("Fence", WHITE)
    for k in range(12):
        x = -7.4 + k * (14.8 / 11)
        prism(white, [(x - 0.42, 0.0, 0), (x + 0.42, 0.0, 0), (x + 0.42, 2.9, 0), (x, 3.45, 0), (x - 0.42, 2.9, 0)], (0, 0, 1), 0.3)
    for y in (0.9, 2.3):
        block(white, (0, y, 0.32), (16.0, 0.4, 0.3), bevel=0.06)
    for sx in (-1, 1):
        block(white, (sx * 7.85, 1.9, 0.15), (0.6, 3.8, 0.6), bevel=0.12)
        block(white, (sx * 7.85, 3.95, 0.15), (0.8, 0.3, 0.8), bevel=0.08)
    return m


def build_cashier_bot():
    """
    Cashier Bot (Area 2 Manager): a hovering mint robot with a paper soda-jerk cap, a white
    monitor head showing a happy green face, a red apron, a relaxed left arm and a pocket nuke
    held in its right hand.

    Animated NPC (owner R30): split into rig pieces (Torso*/Head*/ArmL*/ArmR*, no legs — the hover
    skirt rides the Torso; see models/_npc_rig.py) so the client ManagerController can glide it
    behind the counter, swing its arms, wave (raises the relaxed left arm) and tap the register.
    """
    from models._npc_rig import rig_split

    m = Model("A2_CashierBot", "ground centre under the hover ring; faces -Z", budget=3000)
    body = m.piece("Body", MINT)
    head = m.piece("Head", WHITE)
    screen = m.piece("Screen", (30, 36, 48), material="Smooth")
    glow = m.piece("FaceGlow", GLOW_GREEN, material="Neon")
    steel = m.piece("Steel", STEEL, material="StudsSmall")
    apron = m.piece("Apron", TOY_RED, material="StudsSmall")
    hover = m.piece("Hover", (120, 220, 255), material="Neon")
    # Hover skirt + glowing ring underneath.
    revolve(hover, [(0.0, 0.25), (1.05, 0.25), (1.05, 0.45), (0.0, 0.45)], segments=16)
    revolve(body, [(0.0, 0.45), (1.25, 0.45), (1.45, 0.9), (1.35, 1.7), (0.0, 1.7)], segments=16)
    block(body, (0, 2.95, 0), (2.7, 2.6, 2.0), bevel=0.4, segments=2)
    # Apron with a white pocket + bow ties at the back.
    block(apron, (0, 2.6, -1.02), (2.0, 1.9, 0.12), bevel=0.05)
    block(head, (0, 2.45, -1.1), (0.9, 0.55, 0.06), bevel=0.02)
    block(apron, (0, 3.45, 0), (2.76, 0.25, 2.06), bevel=0.04)
    # Neck + monitor head with a smiley screen face.
    cylinder(steel, (0, 4.2, 0), (0, 4.6, 0), 0.35, segments=10)
    block(head, (0, 5.6, 0), (2.8, 2.1, 1.9), bevel=0.4, segments=2)
    block(screen, (0, 5.6, -0.92), (2.2, 1.5, 0.12), bevel=0.06)
    for sx in (-1, 1):
        # Happy closed "^" eyes.
        bar(glow, (sx * 0.55 - 0.2, 5.85, -1.0), (sx * 0.55, 6.08, -1.0), 0.12)
        bar(glow, (sx * 0.55, 6.08, -1.0), (sx * 0.55 + 0.2, 5.85, -1.0), 0.12)
    toy_face(glow, None, (0, 5.75, 0), 1.0, scale=0.9, smile=True, eyes=False)
    # Ear bolts + antenna with a bulb.
    for sx in (-1, 1):
        revolve(apron, [(0.0, -0.15), (0.35, -0.15), (0.35, 0.15), (0.0, 0.15)], center=(sx * 1.45, 5.6, 0), segments=10, rot=rot_z(90))
    cylinder(steel, (0.5, 6.6, 0.2), (0.7, 7.5, 0.2), 0.08, segments=6)
    ellipsoid(glow, (0.72, 7.6, 0.2), (0.2, 0.2, 0.2), rings=4, segments=8)
    # Paper soda-jerk cap: red band + white crown.
    block(apron, (-0.35, 6.75, 0), (1.9, 0.3, 1.5), bevel=0.08)
    block(head, (-0.35, 7.05, 0), (1.7, 0.35, 1.3), bevel=0.1)
    # Arms: left relaxed at its side (the client raises it to wave), right holding a nuke.
    bar(steel, (-1.35, 3.8, 0), (-1.8, 2.4, -0.1), 0.32)
    ellipsoid(steel, (-1.85, 2.2, -0.1), (0.38, 0.38, 0.38), rings=5, segments=8)
    bar(steel, (1.35, 3.8, 0), (1.9, 2.9, -1.1), 0.32)
    ellipsoid(steel, (1.95, 2.8, -1.2), (0.38, 0.38, 0.38), rings=5, segments=8)
    nb = m.piece("NukeBody", YELLOW, material="StudsSmall")
    mini_nuke(nb, head, screen, glow, (1.95, 3.05, -1.2), length=1.3, radius=0.32)
    # Body-part pieces for the client NPC rig: torso pivots low on the hover skirt, the nuke rides
    # the right hand.
    bones = {
        "Torso": ((0.0, 0.9, 0.0), (0.0, 4.4, 0.0)),
        "Head": ((0.0, 4.5, 0.0), (0.0, 7.6, 0.0)),
        "ArmL": ((-1.35, 3.8, 0.0), (-1.85, 2.2, -0.1)),
        "ArmR": ((1.35, 3.8, 0.0), (1.95, 2.8, -1.2)),
    }
    rig_split(m, bones, assign={"NukeBody": "ArmR"})
    return m


def build_picnic_table():
    """Picnic table with attached benches and a red/white striped umbrella (placed 4x)."""
    m = Model("A2_PicnicTable", "ground centre; table runs along X", budget=1800)
    wood = m.piece("Wood", WOOD)
    legs = m.piece("Legs", WOOD_DARK)
    red = m.piece("UmbrellaRed", TOY_RED)
    white = m.piece("UmbrellaWhite", WHITE)
    pole = m.piece("Pole", STEEL, material="StudsSmall")
    for i in range(3):
        block(wood, (0, 2.6, -0.8 + 0.8 * i), (6.0, 0.25, 0.75), bevel=0.06)
    for sz in (-1, 1):
        block(wood, (0, 1.5, sz * 2.0), (6.0, 0.25, 0.9), bevel=0.06)
    for sx in (-1, 1):
        # A-frame legs.
        bar(legs, (sx * 2.2, 0.0, -2.2), (sx * 2.2, 2.5, 0.0), 0.3)
        bar(legs, (sx * 2.2, 0.0, 2.2), (sx * 2.2, 2.5, 0.0), 0.3)
        block(legs, (sx * 2.2, 1.35, 0), (0.3, 0.25, 4.6), bevel=0.04)
    cylinder(pole, (0, 0, 0), (0, 6.6, 0), 0.14, segments=8)
    striped_cone(red, white, (0, 5.6, 0), 4.0, 1.4, wedges=8)
    ellipsoid(white, (0, 7.05, 0), (0.25, 0.2, 0.25), rings=4, segments=8)
    return m


BUILDERS = {
    "A2_Lot": build_lot,
    "A2_EntryArch": build_arch,
    "A2_Yard": build_yard,
    "A2_StandCounter": build_counter,
    "A2_Awning": build_awning,
    "A2_Register": build_register,
    "A2_TipJar": build_tip_jar,
    "A2_NeonSign": build_neon_sign,
    "A2_Fridge": build_fridge,
    "A2_FenceRun": build_fence_run,
    "A2_CashierBot": build_cashier_bot,
    "A2_PicnicTable": build_picnic_table,
}
