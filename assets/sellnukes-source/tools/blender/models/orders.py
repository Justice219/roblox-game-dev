"""
orders.py — the R90 Order Window art set (docs/superpowers/specs/2026-10-31-r90-hands-on-design.md §1,
docs/orders.md). Every model is ROBLOX space (studs, +Y up, front = -Z, pivot at the ground centre
unless noted), stud material by default (docs/world-art.md), one colour per piece.

Windows (server-built on the plot next to the first producer area; MeshLibrary falls back to stud
boxes per piece until uploaded). Footprint ~6 x 4 studs, ~7.6 tall. The serving ledge's top is at
y ~3.1 and its front edge at z ~-2.2, matching OrderConfig.Counter (0, 3.1, -1.9):
    Order_Window_Town   Nuke Town candy kiosk: white walls, red trim + candy-striped awning, a
                        yellow ORDERS board with a trefoil, warm bulbs over the window
    Order_Window_Dino   Dino Valley tiki hut: stone slab + counter, log posts, woven walls, a
                        stepped straw roof (stud steps), palm fronds, a big bone over the window
    Order_Window_Moon   Moon Base capsule booth: white shell on landing legs, glass dome, dish
                        antenna, a cyan neon strip and a pink beacon

Customers (client-only, animated by Client/Orders/OrderCustomers; ~3 studs tall, toy-sized).
Pieces are named "<Group><Colour>" with Group in Torso / Head / ArmL / ArmR / LegL / LegR so the
client swings each group about its joint (OrderConfig.Rigs — the joints below MUST match):
    Order_Customer_Robot  wind-up toy robot (tinted chest, silver head + limbs, glowing eyes,
                          antenna bulb, wind-up key on its back)
    Order_Customer_Dino   baby dino (tinted skin, cream belly, orange back spikes, big eyes)
    Order_Customer_Alien  little alien (tinted suit, lime head with three eyes, pink antenna bulbs)

Props (client-only):
    Order_CarryNuke  a small cartoon nuke (~1.25 tall) carried stacked in the hands and drawn on
                     the trays; Body is tinted (plain red / the order's flavour colour)
    Order_Tray       a little output tray that sticks out of a producer's front: pivot = the tray
                     top's centre (nukes sit at y = 0), back edge at z = +0.75 against the machine

    Order_Box        owner R115: a takeout box (tinted) with a lid handle and a trefoil sticker
                     that the window's manager hands to an auto-served customer (pivot = centre)

Budgets: windows <= 3,000 triangles (kiosk), customers <= 1,800, tray <= 800, carried nuke <= 500
(up to 6 per character are drawn).
"""

from __future__ import annotations

from snkit.core import (
    CHARCOAL,
    CONCRETE,
    CONCRETE_DARK,
    CREAM,
    DARK_STEEL,
    GLASS,
    GLOW_GREEN,
    GRASS,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LAMP_WARM,
    LEAF,
    LIME,
    Model,
    OFF_WHITE,
    ORANGE,
    PURPLE,
    STEEL,
    TOY_RED,
    WHITE,
    WOOD,
    WOOD_DARK,
)
from snkit.kit import disc, nuke_body, trefoil
from snkit.shapes import bar, box, cylinder, ellipsoid, revolve, ring_tube, rot_x

from models._critter_kit import (
    HOT_PINK,
    SILVER,
    SNOW,
    SOFT_BLACK,
    eyes,
    oriented_ellipsoid,
    star,
    surface,
    tup,
)

# Extra colours of this set (the shared palette lives in snkit.core).
STRAW = (226, 190, 92)
NEON_CYAN = (90, 230, 255)

# --------------------------------------------------------------------------------------------------
# Windows
# --------------------------------------------------------------------------------------------------

# Shared kiosk shell numbers: walls 5.4 wide x 3.4 deep, window opening between y 2.8 and 5.1.
WALL_W = 5.4
WALL_D = 3.4
COUNTER_Y = 2.95  # ledge centre; 0.25 thick -> top 3.075
COUNTER_Z = -1.75  # ledge centre; 0.9 deep -> front edge -2.2


def _shell(walls, low_top=2.8, header_y=5.55, height=5.6, base_y=0.4):
    """Back wall, two side walls, the wall under the window and the header above it."""
    cy = base_y + height / 2
    box(walls, (0, cy, WALL_D / 2 - 0.1), (WALL_W, height, 0.4))
    for side in (-1, 1):
        box(walls, (side * (WALL_W / 2 - 0.2), cy, 0), (0.4, height, WALL_D))
    low_h = low_top - base_y
    box(walls, (0, base_y + low_h / 2, -WALL_D / 2 + 0.2), (WALL_W, low_h, 0.4))
    box(walls, (0, header_y, -WALL_D / 2 + 0.2), (WALL_W, 0.9, 0.4))


def _counter(piece, width=5.6):
    """The serving ledge customers face (top 3.075, front edge z -2.2)."""
    box(piece, (0, COUNTER_Y, COUNTER_Z), (width, 0.25, 0.9), bevel=0.06)


def build_window_town():
    """Nuke Town candy kiosk with a striped awning and the ORDERS board."""
    m = Model("Order_Window_Town", "ground centre; serving window faces -Z (the road)", budget=3000)
    base = m.piece("Base", WOOD)
    walls = m.piece("Walls", WHITE)
    counter = m.piece("Counter", WOOD_DARK)
    trim = m.piece("Trim", TOY_RED, material="StudsSmall")
    awning_red = m.piece("AwningRed", TOY_RED, material="StudsSmall")
    awning_white = m.piece("AwningWhite", WHITE, material="StudsSmall")
    sign = m.piece("Sign", HAZARD_YELLOW)
    mark = m.piece("SignMark", HAZARD_BLACK, material="Smooth")
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")

    box(base, (0, 0.2, 0), (5.8, 0.4, 3.8), bevel=0.08)
    _shell(walls)
    box(walls, (0, 6.15, 0.05), (5.8, 0.3, 3.8), bevel=0.06)  # flat roof
    _counter(counter)
    # Red corner posts + window side frames.
    for sx in (-1, 1):
        for sz in (-1, 1):
            box(trim, (sx * 2.65, 3.2, sz * 1.65), (0.5, 5.6, 0.5), bevel=0.08)
        box(trim, (sx * 2.15, 3.95, -1.62), (0.25, 2.3, 0.3))
    # Candy-striped awning sloping down toward the road (6 stripes) + scalloped front edge.
    slope = rot_x(-22)
    for i in range(6):
        x = -2.5 + i * 1.0
        piece = awning_red if i % 2 == 0 else awning_white
        box(piece, (x, 5.75, -2.35), (1.0, 0.14, 1.9), rot=slope)
        oriented_ellipsoid(piece, (x, 5.33, -3.22), (0.5, 0.22, 0.1), normal=(0, 0, -1), rings=4, segments=8)
    # ORDERS board on the roof with a trefoil emblem.
    box(sign, (0, 7.0, -0.2), (4.2, 1.1, 0.25), bevel=0.06)
    box(sign, (-1.6, 6.55, -0.2), (0.2, 0.5, 0.2))
    box(sign, (1.6, 6.55, -0.2), (0.2, 0.5, 0.2))
    trefoil(mark, (0, 7.0, -0.36), 0.42, 0.06, normal=(0, 0, -1))
    # Warm bulbs along the top of the window.
    for i in range(5):
        ellipsoid(bulbs, (-1.8 + i * 0.9, 5.0, -1.78), (0.13, 0.13, 0.13), rings=4, segments=8)
    return m


def build_window_dino():
    """Dino Valley tiki hut: stone, logs, a stepped straw roof, palm fronds and a bone sign."""
    m = Model("Order_Window_Dino", "ground centre; serving window faces -Z (the road)", budget=3000)
    base = m.piece("Base", CONCRETE_DARK)
    posts = m.piece("Posts", WOOD_DARK)
    walls = m.piece("Walls", WOOD)
    counter = m.piece("Counter", CONCRETE)
    roof = m.piece("Roof", STRAW)
    leaves = m.piece("Leaves", LEAF, material="StudsSmall")
    bone = m.piece("Bone", OFF_WHITE, material="Smooth")

    box(base, (0, 0.22, 0), (5.8, 0.45, 3.8), bevel=0.15)
    for sx in (-1, 1):
        for sz in (-1, 1):
            cylinder(posts, (sx * 2.55, 0.4, sz * 1.55), (sx * 2.55, 5.9, sz * 1.55), 0.3, segments=8)
    _shell(walls, height=5.3, header_y=5.45)
    _counter(counter)
    # Stepped straw roof (stud-built thatch).
    for i, (w, d) in enumerate(((6.6, 4.8), (5.4, 3.8), (4.0, 2.7), (2.4, 1.6))):
        box(roof, (0, 6.0 + i * 0.45, 0.05), (w, 0.45, d), bevel=0.08)
    # Palm fronds drooping off the roof corners.
    for sx in (-1, 1):
        for sz in (-1, 1):
            oriented_ellipsoid(
                leaves,
                (sx * 3.2, 5.75, sz * 2.25),
                (1.0, 0.45, 0.08),
                normal=(0, 0.85, 0),
                up=(sx, -0.6, sz),
                rings=4,
                segments=8,
            )
    # Big cartoon bone over the window.
    cylinder(bone, (-1.25, 5.45, -1.82), (1.25, 5.45, -1.82), 0.17, segments=10)
    for sx in (-1, 1):
        for sy in (-1, 1):
            ellipsoid(bone, (sx * 1.38, 5.45 + sy * 0.17, -1.82), (0.22, 0.22, 0.2), rings=5, segments=8)
    return m


def build_window_moon():
    """Moon Base capsule booth on landing legs with a glass dome, dish and beacon."""
    m = Model("Order_Window_Moon", "ground centre; serving window faces -Z (the road)", budget=3000)
    legs = m.piece("Legs", DARK_STEEL)
    shell = m.piece("Shell", WHITE)
    counter = m.piece("Counter", STEEL, material="Smooth")
    trim = m.piece("Trim", NEON_CYAN, material="Neon")
    dome = m.piece("Dome", GLASS, material="Glass", transparency=0.35)
    dish = m.piece("Dish", SILVER, material="StudsSmall")
    beacon = m.piece("Beacon", HOT_PINK, material="Neon")

    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(legs, (sx * 2.0, 1.2, sz * 1.2), (sx * 2.65, 0.1, sz * 1.75), 0.24)
            disc(legs, (sx * 2.7, 0, sz * 1.8), 0.38, 0.12, segments=10, bevel=0.03)
    box(shell, (0, 1.0, 0), (WALL_W, 0.4, WALL_D), bevel=0.1)  # floor plate
    _shell(shell, base_y=1.2, height=4.6, header_y=5.3)
    box(shell, (0, 5.75, 0.05), (5.7, 0.35, 3.7), bevel=0.12)  # roof ring
    _counter(counter)
    box(trim, (0, 5.62, -1.92), (5.0, 0.1, 0.08))
    ellipsoid(dome, (0, 5.9, 0.05), (1.9, 1.25, 1.35), rings=8, segments=16)
    # Dish antenna on a short mast (dish faces up / toward the road).
    cylinder(dish, (1.9, 5.9, 1.1), (1.9, 6.7, 1.1), 0.08, segments=8)
    revolve(
        dish,
        [(0.0, 0.0), (0.55, 0.12), (0.62, 0.2), (0.0, 0.08)],
        center=(1.9, 6.75, 1.1),
        segments=14,
        closed=True,
        rot=rot_x(-25),
    )
    ellipsoid(beacon, (0, 7.25, 0.05), (0.18, 0.18, 0.18), rings=5, segments=8)
    return m


# --------------------------------------------------------------------------------------------------
# Customers (joints must match OrderConfig.Rigs)
# --------------------------------------------------------------------------------------------------


def build_customer_robot():
    """Wind-up toy robot. Joints: Torso (0, 0.95, 0), Head (0, 2.05, 0), ArmL/R (-/+0.86, 1.8, 0),
    LegL/R (-/+0.38, 0.95, 0)."""
    m = Model("Order_Customer_Robot", "ground centre between the feet; faces -Z", budget=1500)
    body = m.piece("TorsoBody", TOY_RED, material="StudsSmall", tinted=True)
    trim = m.piece("TorsoTrim", DARK_STEEL, material="Smooth")
    key = m.piece("TorsoKey", HAZARD_YELLOW, material="Smooth")
    lights = m.piece("TorsoLights", GLOW_GREEN, material="Neon")
    head = m.piece("HeadBody", SILVER, material="StudsSmall")
    face = m.piece("HeadFace", CHARCOAL, material="Smooth")
    glow = m.piece("HeadGlow", GLOW_GREEN, material="Neon")
    legs = {-1: m.piece("LegLBody", SILVER, material="StudsSmall"), 1: m.piece("LegRBody", SILVER, material="StudsSmall")}
    arms = {-1: m.piece("ArmLBody", SILVER, material="StudsSmall"), 1: m.piece("ArmRBody", SILVER, material="StudsSmall")}

    # Legs + feet (hip joints at y 0.95).
    for side, leg in legs.items():
        box(leg, (side * 0.38, 0.6, 0), (0.42, 0.7, 0.46), bevel=0.05)
        box(leg, (side * 0.38, 0.13, -0.08), (0.56, 0.26, 0.72), bevel=0.06)
    # Boxy body (tinted), waist ring, chest lights, wind-up key on the back.
    box(body, (0, 1.5, 0), (1.4, 1.05, 0.95), bevel=0.12)
    box(trim, (0, 0.99, 0), (1.22, 0.12, 0.86))
    for i in (-1, 0, 1):
        box(lights, (i * 0.3, 1.66, -0.49), (0.2, 0.2, 0.06))
    cylinder(key, (0, 1.55, 0.47), (0, 1.55, 0.78), 0.07, segments=8)
    for side in (-1, 1):
        oriented_ellipsoid(key, (side * 0.22, 1.55, 0.82), (0.2, 0.15, 0.05), normal=(0, 0, 1), rings=4, segments=8)
    # Head (neck at y 2.05): box head, ear bolts, mouth grille, antenna + glowing bulb + eyes.
    box(head, (0, 2.46, 0), (1.1, 0.8, 0.9), bevel=0.12)
    for side in (-1, 1):
        cylinder(face, (side * 0.55, 2.46, 0), (side * 0.68, 2.46, 0), 0.13, segments=8)
        box(glow, (side * 0.24, 2.52, -0.46), (0.24, 0.24, 0.06))
    for i in (-1, 0, 1):
        box(face, (i * 0.16, 2.23, -0.46), (0.09, 0.14, 0.05))
    cylinder(face, (0, 2.86, 0), (0, 3.14, 0), 0.05, segments=6)
    ellipsoid(glow, (0, 3.2, 0), (0.12, 0.12, 0.12), rings=4, segments=8)
    # Arms (shoulders at y 1.8): shoulder ball, upper arm, claw.
    for side, arm in arms.items():
        ellipsoid(arm, (side * 0.82, 1.84, 0), (0.2, 0.2, 0.2), rings=5, segments=8)
        cylinder(arm, (side * 0.86, 1.8, 0), (side * 0.86, 1.18, 0), 0.13, segments=8)
        box(arm, (side * 0.86, 1.05, -0.02), (0.26, 0.24, 0.3), bevel=0.04)
    return m


def build_customer_dino():
    """Baby dino. Joints: Torso (0, 0.8, 0), Head (0, 1.75, -0.25), ArmL/R (-/+0.55, 1.45, -0.4),
    LegL/R (-/+0.45, 0.75, 0.05)."""
    m = Model("Order_Customer_Dino", "ground centre between the feet; faces -Z", budget=1800)
    skin = m.piece("TorsoSkin", GRASS, material="StudsSmall", tinted=True)
    belly = m.piece("TorsoBelly", CREAM, material="StudsSmall")
    spikes = m.piece("TorsoSpikes", ORANGE, material="Smooth")
    head = m.piece("HeadSkin", GRASS, material="StudsSmall", tinted=True)
    face = m.piece("HeadEyes", SOFT_BLACK, material="Smooth")
    shine = m.piece("HeadShine", SNOW, material="Smooth")
    legs = {
        -1: m.piece("LegLSkin", GRASS, material="StudsSmall", tinted=True),
        1: m.piece("LegRSkin", GRASS, material="StudsSmall", tinted=True),
    }
    arms = {
        -1: m.piece("ArmLSkin", GRASS, material="StudsSmall", tinted=True),
        1: m.piece("ArmRSkin", GRASS, material="StudsSmall", tinted=True),
    }

    # Round body + tapering tail + cream belly + back spikes.
    ellipsoid(skin, (0, 1.15, 0.05), (0.62, 0.6, 0.55), rings=8, segments=12)
    cylinder(skin, (0, 0.95, 0.45), (0, 0.55, 1.3), 0.3, segments=10, radius_b=0.06)
    oriented_ellipsoid(belly, (0, 1.1, -0.38), (0.42, 0.45, 0.16), normal=(0, 0, -1), rings=6, segments=10)
    for y, z in ((1.72, 0.12), (1.58, 0.42), (1.3, 0.68), (1.02, 0.95), (0.8, 1.15)):
        cylinder(spikes, (0, y - 0.08, z), (0, y + 0.18, z + 0.1), 0.13, segments=6, radius_b=0.015)
    # Big head + snout (neck at y 1.75) with eyes and nostrils.
    head_c, head_r = (0, 2.2, -0.35), (0.58, 0.52, 0.55)
    ellipsoid(head, head_c, head_r, rings=8, segments=14)
    ellipsoid(head, (0, 2.04, -0.8), (0.38, 0.27, 0.3), rings=6, segments=10)
    eyes(face, shine, head_c, head_r, yaw=30, pitch=14, size=0.15)
    for side in (-1, 1):
        oriented_ellipsoid(face, (side * 0.12, 2.12, -1.08), (0.04, 0.04, 0.02), normal=(0, 0, -1), rings=3, segments=6)
    # Stubby legs + round feet (hips at y 0.75).
    for side, leg in legs.items():
        cylinder(leg, (side * 0.45, 0.75, 0.05), (side * 0.45, 0.16, 0.05), 0.22, segments=10)
        ellipsoid(leg, (side * 0.45, 0.12, -0.05), (0.27, 0.13, 0.34), rings=5, segments=10)
    # Tiny arms reaching forward (shoulders at y 1.45).
    for side, arm in arms.items():
        cylinder(arm, (side * 0.55, 1.45, -0.4), (side * 0.62, 1.16, -0.62), 0.1, segments=8)
        ellipsoid(arm, (side * 0.63, 1.12, -0.66), (0.12, 0.12, 0.12), rings=4, segments=8)
    return m


def build_customer_alien():
    """Little alien. Joints: Torso (0, 0.85, 0), Head (0, 1.75, 0), ArmL/R (-/+0.6, 1.55, 0),
    LegL/R (-/+0.32, 0.85, 0)."""
    m = Model("Order_Customer_Alien", "ground centre between the feet; faces -Z", budget=1800)
    suit = m.piece("TorsoSuit", PURPLE, material="StudsSmall", tinted=True)
    belt = m.piece("TorsoBelt", HAZARD_YELLOW, material="Smooth")
    head = m.piece("HeadSkin", LIME, material="StudsSmall")
    face = m.piece("HeadEyes", SOFT_BLACK, material="Smooth")
    shine = m.piece("HeadShine", SNOW, material="Smooth")
    glow = m.piece("HeadGlow", HOT_PINK, material="Neon")
    legs = {
        -1: m.piece("LegLSuit", PURPLE, material="StudsSmall", tinted=True),
        1: m.piece("LegRSuit", PURPLE, material="StudsSmall", tinted=True),
    }
    arms = {-1: m.piece("ArmLSkin", LIME, material="StudsSmall"), 1: m.piece("ArmRSkin", LIME, material="StudsSmall")}

    # Space-suit body + belt + a star badge.
    ellipsoid(suit, (0, 1.25, 0), (0.5, 0.5, 0.42), rings=8, segments=12)
    ring_tube(belt, (0, 1.0, 0), 0.46, 0.1, 0.12, segments=16)
    star(belt, (0, 1.42, -0.43), 0.14, 0.05, normal=(0, 0, -1))
    # Big head (neck at y 1.75) with three eyes + antennae.
    head_c, head_r = (0, 2.25, 0), (0.7, 0.55, 0.6)
    ellipsoid(head, head_c, head_r, rings=8, segments=14)
    eyes(face, shine, head_c, head_r, yaw=32, pitch=4, size=0.15)
    p, n = surface(head_c, head_r, 0, 22)
    oriented_ellipsoid(face, tup(p - n * 0.035), (0.13, 0.16, 0.06), normal=tup(n), rings=6, segments=10)
    for side in (-1, 1):
        cylinder(head, (side * 0.25, 2.7, 0), (side * 0.45, 3.15, 0), 0.04, segments=6)
        ellipsoid(glow, (side * 0.46, 3.24, 0), (0.11, 0.11, 0.11), rings=4, segments=8)
    # Legs with boots (hips at y 0.85).
    for side, leg in legs.items():
        cylinder(leg, (side * 0.32, 0.85, 0), (side * 0.32, 0.2, 0), 0.16, segments=8)
        ellipsoid(leg, (side * 0.32, 0.13, -0.06), (0.22, 0.14, 0.28), rings=5, segments=10)
    # Arms (shoulders at y 1.55).
    for side, arm in arms.items():
        cylinder(arm, (side * 0.6, 1.55, 0), (side * 0.72, 1.06, -0.05), 0.1, segments=8)
        ellipsoid(arm, (side * 0.73, 1.0, -0.06), (0.13, 0.13, 0.13), rings=4, segments=8)
    return m


# --------------------------------------------------------------------------------------------------
# Props
# --------------------------------------------------------------------------------------------------


def build_carry_nuke():
    """Small cartoon nuke for the carried stack + trays (Body tinted)."""
    m = Model("Order_CarryNuke", "centre under the fins; nose up (+Y)", budget=500)
    body = m.piece("Body", TOY_RED, material="StudsSmall", tinted=True)
    nose = m.piece("Nose", WHITE, material="StudsSmall")
    fins = m.piece("Fins", CHARCOAL, material="StudsSmall")
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    nuke_body(body, nose, fins, core, base=(0, 0, 0), length=1.25, radius=0.3, segments=10)
    return m


def build_tray():
    """Output tray: studded yellow plate, steel lips + back plate + struts, a green ready light."""
    m = Model("Order_Tray", "top centre of the plate; back edge (z +0.75) against the machine", budget=800)
    plate = m.piece("Plate", HAZARD_YELLOW)
    rim = m.piece("Rim", DARK_STEEL, material="Smooth")
    light = m.piece("Light", GLOW_GREEN, material="Neon")
    box(plate, (0, -0.09, 0), (2.6, 0.18, 1.5), bevel=0.04)
    box(rim, (0, 0.05, -0.8), (2.7, 0.3, 0.12))
    for side in (-1, 1):
        box(rim, (side * 1.36, 0.05, 0), (0.12, 0.3, 1.6))
        bar(rim, (side * 1.0, -0.18, 0.55), (side * 1.0, -0.85, 0.78), 0.14)
    box(rim, (0, 0.25, 0.8), (2.7, 0.7, 0.12))
    box(light, (0.95, 0.42, 0.73), (0.26, 0.14, 0.06))
    return m


def build_box():
    """Owner R115: the takeout box the window's manager hands to an auto-served customer."""
    m = Model("Order_Box", "box centre (it flies: no ground pivot)", budget=400)
    box_piece = m.piece("Box", TOY_RED, material="StudsSmall", tinted=True)
    lid = m.piece("Lid", WHITE, material="StudsSmall")
    sticker = m.piece("Sticker", HAZARD_YELLOW, material="Smooth")
    mark = m.piece("Mark", HAZARD_BLACK, material="Smooth")
    box(box_piece, (0, -0.08, 0), (1.0, 0.74, 0.8), bevel=0.06)
    # Folded lid flaps meeting in a ridge + a carry handle loop.
    box(lid, (0, 0.34, 0), (1.04, 0.12, 0.84), bevel=0.03)
    box(lid, (0, 0.52, 0), (0.12, 0.3, 0.5))
    box(lid, (0, 0.66, 0), (0.12, 0.08, 0.36))
    # Yellow trefoil sticker on the front (-Z).
    box(sticker, (0, -0.06, -0.41), (0.46, 0.46, 0.04), bevel=0.02)
    trefoil(mark, (0, -0.06, -0.44), 0.16, 0.03, normal=(0, 0, -1))
    return m


BUILDERS = {
    "Order_Window_Town": build_window_town,
    "Order_Window_Dino": build_window_dino,
    "Order_Window_Moon": build_window_moon,
    "Order_Customer_Robot": build_customer_robot,
    "Order_Customer_Dino": build_customer_dino,
    "Order_Customer_Alien": build_customer_alien,
    "Order_CarryNuke": build_carry_nuke,
    "Order_Tray": build_tray,
    "Order_Box": build_box,
}
