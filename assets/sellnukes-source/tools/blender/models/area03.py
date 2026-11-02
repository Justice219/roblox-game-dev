"""
area03.py — Area 3 "BoomDash Delivery" scene models (B8a): the HQ of BoomDash, an ORIGINAL parody
delivery-app brand (orange + sunny yellow, a comic "boom" starburst logo; no real logos), with
scooters zipping around a lane loop, a van, a giant phone showing the app and a GPS beacon.

    A3_Lot            light paving + dark scooter lane loop (stadium) + grass island + parking   base
    A3_EntryArch      "BOOMDASH" block-letter arch in brand orange                               base
    A3_Yard           island star flower bed, bushes, round trees                               base
    A3_HQ             the producer "BoomDash Orders": HQ building, pickup window, logo fascia    A3_HQShell
    A3_ScooterRack    charging rack with an orange shelter roof and a charge kiosk              A3_ScooterRack
    A3_Scooter        cute delivery scooter with a branded box (placed 6x)                       A3_Scooters
    A3_GPSBeacon      roof mast with a dish and a giant glowing map pin                          A3_GPS
    A3_AppPhone       giant smartphone on a kickstand showing the BoomDash app                   A3_MobileApp
    A3_DeliveryVan    boxy branded van with a pocket-nuke roof mascot                            A3_DeliveryVan
    A3_ParkingLot     stall lines, wheel stops, loading-zone stripes, P sign, two lamps          A3_ParkingLot
    A3_Dispatcher     the Manager: headset-wearing dispatcher at a desk with a route screen      A3_Dispatcher
    A3_Lamp           orange-caged lane lamp, one mesh instanced 4x (base) + 2x (parking lot)    base / A3_ParkingLot

Lane loop (for scooter "zipping" FX, B4/B6): stadium centre (0, 30) slot-local, straight half-
length 22 along X, centreline end radius 9, lane width 4.5, surface y = 0.56. Exported in the
layout file as `lane` (Area03.luau) so runtime FX can move scooters along it.
Placement: src/shared/Config/AreaLayouts/Area03.luau. Shared helpers: models/area01.py.
"""

from __future__ import annotations

import math

from mathutils import Vector
from models.area01 import (
    BARK,
    LOT_TOP,
    SKIN,
    SLOT_PIVOT,
    SOIL,
    block_text,
    sign_text,
    entry_arch,
    lot_stripes,
    mini_nuke,
    round_tree,
    tiny_nuke,
    toy_figure,
    wheel,
)
from snkit.core import (
    CHARCOAL,
    CONCRETE,
    CONCRETE_DARK,
    DARK_STEEL,
    DEEP_BLUE,
    GLASS,
    GLOW_GREEN,
    GRASS,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LAMP_WARM,
    LEAF,
    MINT,
    Model,
    ORANGE,
    ROAD,
    SIDEWALK,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    TYRE,
    WHITE,
    YELLOW,
)
from snkit.kit import block, disc, hazard_floor, lamp, truss
from snkit.shapes import bar, box, cylinder, ellipsoid, extrude_outline, prism, revolve, rot_x, rot_y, rot_z

# Lane loop geometry (slot-local) — mirrored in Area03.luau `lane`.
LANE_C = (0.0, 30.0)
LANE_HALF = 22.0
LANE_R = 9.0
LANE_W = 4.5
LANE_TOP = LOT_TOP + 0.06
PAVE_LIGHT = (214, 216, 226)
KRAFT = (204, 152, 98)
BRAND = ORANGE  # BoomDash primary


def _facing_basis(facing):
    """(right, up, outward normal) for a decal on a face looking toward `facing` ("-z", "+x", "-x", "+z")."""
    return {
        "-z": ((-1, 0, 0), (0, 1, 0), (0, 0, -1)),
        "+z": ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
        "+x": ((0, 0, -1), (0, 1, 0), (1, 0, 0)),
        "-x": ((0, 0, 1), (0, 1, 0), (-1, 0, 0)),
    }[facing]


def boom_logo(star, disc_piece, ink, center, radius, facing="-z", letter=True, depth=0.16):
    """
    BoomDash logo decal: 12-spike (8 when small) yellow comic starburst, orange inner disc, white "B"
    (on +-Z faces, which block_text can letter) or three white speed lines on side faces.
    center = point on the face; the decal stands proud of it along the face normal.
    """
    (rx, ry, rz), (ux, uy, uz), (nx, ny, nz) = _facing_basis(facing)
    cx, cy, cz = center

    def at(u, v, out):
        return (cx + rx * u + ux * v + nx * out, cy + ry * u + uy * v + ny * out, cz + rz * u + uz * v + nz * out)

    # R11 (mobile first): hero logos (radius >= 1.5) get 12 spikes, small decals 8 spikes + a
    # 10-sided disc, so props placed many times (scooters) stay cheap.
    spikes = 12 if radius >= 1.5 else 8
    sides = 16 if radius >= 1.5 else 10
    pts = []
    for k in range(2 * spikes):
        r = radius if k % 2 == 0 else radius * 0.72
        a = math.pi / 2 + math.pi * k / spikes
        pts.append(at(r * math.cos(a), r * math.sin(a), depth / 2))
    prism(star, pts, (nx, ny, nz), depth)
    ring = [at(radius * 0.58 * math.cos(2 * math.pi * k / sides), radius * 0.58 * math.sin(2 * math.pi * k / sides), depth + 0.05) for k in range(sides)]
    prism(disc_piece, ring, (nx, ny, nz), 0.1)
    if letter and facing in ("-z", "+z"):
        out = -1 if facing == "-z" else 1
        block_text(ink, "B", (cx, cy, cz + out * (depth + 0.1)), radius * 0.11, 0.08, facing=facing)
    else:
        for k, (du, dv) in enumerate(((-0.3, 0.22), (-0.15, 0.0), (-0.3, -0.22))):
            u0, v0 = du * radius, dv * radius
            prism(ink, [at(u0 - 0.25 * radius, v0 - 0.05 * radius, depth + 0.12), at(u0 + 0.35 * radius, v0 - 0.05 * radius, depth + 0.12),
                        at(u0 + 0.35 * radius, v0 + 0.05 * radius, depth + 0.12), at(u0 - 0.25 * radius, v0 + 0.05 * radius, depth + 0.12)], (nx, ny, nz), 0.06)


def _stadium_ring(piece, r_in, r_out, y0, y1, arc_steps=10):
    """Extrude the ring between two concentric stadiums (lane, edge lines) around LANE_C."""
    cx, cz = LANE_C
    for sz in (-1, 1):
        # Straights (front z < centre, back z > centre).
        z_a, z_b = cz + sz * r_in, cz + sz * r_out
        extrude_outline(piece, [(cx - LANE_HALF, z_a), (cx + LANE_HALF, z_a), (cx + LANE_HALF, z_b), (cx - LANE_HALF, z_b)], y0, y1)
    for sx in (-1, 1):
        ex = cx + sx * LANE_HALF
        for k in range(arc_steps):
            a0 = -math.pi / 2 + math.pi * k / arc_steps
            a1 = -math.pi / 2 + math.pi * (k + 1) / arc_steps
            pts = [
                (ex + sx * r_in * math.cos(a0), cz + r_in * math.sin(a0)),
                (ex + sx * r_out * math.cos(a0), cz + r_out * math.sin(a0)),
                (ex + sx * r_out * math.cos(a1), cz + r_out * math.sin(a1)),
                (ex + sx * r_in * math.cos(a1), cz + r_in * math.sin(a1)),
            ]
            extrude_outline(piece, pts, y0, y1)


def _stadium_fill(piece, r, y0, y1, arc_steps=10):
    """Solid stadium (island) around LANE_C with end radius r."""
    cx, cz = LANE_C
    pts = [(cx - LANE_HALF, cz - r), (cx + LANE_HALF, cz - r)]
    for k in range(1, arc_steps):
        a = -math.pi / 2 + math.pi * k / arc_steps
        pts.append((cx + LANE_HALF + r * math.cos(a), cz + r * math.sin(a)))
    pts += [(cx + LANE_HALF, cz + r), (cx - LANE_HALF, cz + r)]
    for k in range(1, arc_steps):
        a = math.pi / 2 + math.pi * k / arc_steps
        pts.append((cx - LANE_HALF + r * math.cos(a), cz + r * math.sin(a)))
    extrude_outline(piece, pts, y0, y1)


# ------------------------------------------------------------------------------------------------
# Base (slot origin pivot)
# ------------------------------------------------------------------------------------------------


def build_lot():
    """Light paving bands, the dark scooter lane loop with orange edges and white dashes, a grass
    island inside it and a plain asphalt parking pad on the +X side."""
    m = Model("A3_Lot", SLOT_PIVOT, budget=2500)  # a whole 104 x 70 lot (~27 tiles of area)
    pave = m.piece("Paving", SIDEWALK)
    pave_b = m.piece("PavingLight", PAVE_LIGHT)
    curb = m.piece("Curb", WHITE)
    lane = m.piece("Lane", ROAD)
    edges = m.piece("LaneEdges", BRAND)
    dashes = m.piece("LaneDashes", WHITE)
    grass = m.piece("Island", GRASS)
    lot_stripes(pave, pave_b, -52, 52, 2.0, 70.0, stripe=6.0, along="x")
    block(curb, (0, LOT_TOP / 2 + 0.05, 1.0), (104.0, LOT_TOP + 0.1, 2.0), bevel=0.15)
    r_in, r_out = LANE_R - LANE_W / 2, LANE_R + LANE_W / 2
    _stadium_ring(lane, r_in, r_out, LOT_TOP, LANE_TOP)
    _stadium_ring(edges, r_out - 0.35, r_out, LANE_TOP, LANE_TOP + 0.04)
    _stadium_ring(edges, r_in, r_in + 0.35, LANE_TOP, LANE_TOP + 0.04)
    # Dashed white centre line: straights + rotated dashes around both ends.
    cx, cz = LANE_C
    for sz in (-1, 1):
        x = cx - LANE_HALF + 1.5
        while x < cx + LANE_HALF - 1.0:
            block(dashes, (x, LANE_TOP + 0.02, cz + sz * LANE_R), (1.8, 0.04, 0.3), bevel=0.0)
            x += 3.2
    for sx in (-1, 1):
        for k in range(1, 6):
            a = -math.pi / 2 + math.pi * k / 6
            px, pz = cx + sx * (LANE_HALF + LANE_R * math.cos(a)), cz + LANE_R * math.sin(a)
            box(dashes, (px, LANE_TOP + 0.02, pz), (0.3, 0.04, 1.8), rot=rot_y(-sx * math.degrees(a)))
    # Grass island (raised 0.12 with a white curb ring).
    _stadium_fill(grass, r_in - 0.3, LOT_TOP, LOT_TOP + 0.14)
    _stadium_ring(curb, r_in - 0.3, r_in, LOT_TOP, LOT_TOP + 0.2)
    # Parking pad (asphalt) on the +X side; the ParkingLot pad paints it later.
    block(lane, (43.0, LOT_TOP + 0.03, 32.0), (16.0, 0.06, 28.0), bevel=0.0)
    return m


def build_arch():
    """BOOMDASH arch: brand-orange posts, white trim, charcoal panel, yellow letters."""
    m = entry_arch(
        "A3_EntryArch",
        "BOOMDASH",
        inner=15.0,
        post_color=BRAND,
        trim_color=WHITE,
        panel_color=CHARCOAL,
        letter_color=YELLOW,
        finial_colors=(TOY_RED, YELLOW),
    )
    return m


def build_yard():
    """
    Island star flower bed + bushes and round trees (the lane lamps are A3_Lamp instances).

    Trees are split into a -X ("L") and a +X ("R") piece: one piece per colour would have a
    bounding box spanning the whole lot, which the client's producer billboard placement
    (ProducerBillboards.place: Workspace:GetPartBoundsInBox over visible parts, owner R31/R32)
    treats as solid in front of the dispatch hub (tests/billboard-clearance.luau). +2 pieces.
    """
    m = Model("A3_Yard", SLOT_PIVOT, budget=3000)
    trunks = {-1: m.piece("TrunksL", BARK), 1: m.piece("TrunksR", BARK)}
    leaves = {-1: m.piece("LeavesL", LEAF), 1: m.piece("LeavesR", LEAF)}
    bush = m.piece("Bushes", (58, 168, 66))
    soil = m.piece("Soil", SOIL)
    petals = m.piece("Petals", YELLOW, material="StudsSmall")
    for x, z, h, c in ((-46, 62, 9.0, 3.2), (-36, 65, 8.0, 2.8), (46, 62, 9.0, 3.2), (-24, 30, 7.0, 2.4), (24, 30, 7.0, 2.4)):
        side = -1 if x < 0 else 1
        round_tree(trunks[side], leaves[side], (x, LOT_TOP + (0.14 if abs(x) == 24 else 0.0), z), height=h, crown=c, segments=8)
    # Star-shaped flower bed in the island centre (the logo in flowers).
    cx, cz = LANE_C
    star = []
    for k in range(10):
        r = 4.6 if k % 2 == 0 else 2.2
        a = math.pi / 2 + math.pi * k / 5
        star.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    extrude_outline(soil, star, LOT_TOP + 0.14, LOT_TOP + 0.5)
    for k in range(5):
        a = math.pi / 2 + 2 * math.pi * k / 5
        for r in (1.4, 2.8):
            block(petals, (cx + r * math.cos(a), LOT_TOP + 0.75, cz + r * math.sin(a)), (0.8, 0.5, 0.8), bevel=0.15)
    block(petals, (cx, LOT_TOP + 0.75, cz), (1.0, 0.5, 1.0), bevel=0.18)
    for x in (-14.0, -8.0, 8.0, 14.0):
        block(bush, (x, LOT_TOP + 0.95, cz), (2.6, 1.6, 2.6), bevel=0.45, segments=2)
    return m


def build_lamp():
    """Lane lamp (orange cage, warm bulb): one shared mesh instanced around the lane + parking."""
    m = Model("A3_Lamp", "ground centre; bulb centre at y ~ 5.7", budget=600)
    lamp(m.piece("Post", DARK_STEEL), m.piece("Cage", BRAND), m.piece("Bulb", LAMP_WARM, material="Neon"), (0, 0, 0), height=6.0, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# Buildings + vehicles
# ------------------------------------------------------------------------------------------------


def build_hq():
    """
    BoomDash HQ (producer "BoomDash Orders"): white building 32 x 16 x 12 on a concrete plinth,
    two big shop windows, a central pickup window with a steel counter of order boxes under a
    striped mini-awning, an orange fascia with the starburst logo + BOOMDASH block letters, a
    charcoal parapet and rooftop vents. Pivot: ground centre, front (-Z) at z = -8.
    """
    m = Model("A3_HQ", "ground centre; facade faces -Z at z = -8; roof top y = 12; pickup counter at y ~ 3.3", budget=6000)
    walls = m.piece("Walls", WHITE)
    brand = m.piece("Brand", BRAND)
    trim = m.piece("Trim", CHARCOAL)
    roof = m.piece("Roof", CONCRETE_DARK, material="StudsLarge")
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.35)
    inside = m.piece("Interior", (44, 58, 96), material="Smooth")
    counter = m.piece("Counter", STEEL, material="StudsSmall")
    boxes = m.piece("Boxes", KRAFT, material="StudsSmall")
    letters = m.piece("Letters", WHITE, material="Smooth")
    star = m.piece("LogoStar", YELLOW, material="Smooth")
    plinth = m.piece("Plinth", CONCRETE)
    W, D, H = 32.0, 16.0, 12.0
    zf = -D / 2
    block(plinth, (0, 0.25, 0), (W + 0.8, 0.5, D + 0.8), bevel=0.15)
    # Back + side walls.
    block(walls, (0, H / 2 + 0.25, D / 2 - 0.5), (W, H - 0.5, 1.0), bevel=0.15)
    for sx in (-1, 1):
        block(walls, (sx * (W / 2 - 0.5), H / 2 + 0.25, 0), (1.0, H - 0.5, D), bevel=0.15)
    # Facade: sill band, piers between the openings, header above them.
    # Sill band 0.1 wider than the building so its ends stand proud of the side walls (R18).
    block(brand, (0, 1.25, zf + 0.5), (W + 0.2, 1.5, 1.2), bevel=0.15)
    for x0, x1 in ((-16.0, -14.5), (-6.5, -4.5), (4.5, 6.5), (14.5, 16.0)):
        block(walls, ((x0 + x1) / 2, 4.75, zf + 0.5), (x1 - x0, 5.5, 1.0), bevel=0.1)
    block(walls, (0, 8.0, zf + 0.5), (W, 1.0, 1.0), bevel=0.1)
    block(walls, (0, 2.25, zf + 0.5), (9.0, 0.5, 1.0), bevel=0.05)
    # Shop windows + frames.
    for cx in (-10.5, 10.5):
        box(glass, (cx, 4.75, zf + 0.5), (8.0, 5.5, 0.2))
        block(brand, (cx, 4.75, zf + 0.35), (0.35, 5.5, 0.4), bevel=0.05)
        block(brand, (cx, 7.55, zf + 0.3), (8.2, 0.35, 0.5), bevel=0.05)  # back face 0.05 off the glass (R18)
    # Interior backdrop + shelves of order boxes seen through the glass and the pickup window.
    box(inside, (0, 4.5, zf + 3.5), (W - 2.2, 7.0, 0.1))
    for sx in (-1, 0, 1):
        for row, y in enumerate((2.0, 4.2, 6.4)):
            for k in range(3):
                bx = sx * 10.5 - 2.6 + 2.6 * k + (0.4 if row % 2 else 0.0)
                block(boxes, (bx, y + 0.65, zf + 2.6), (1.6, 1.3, 1.4), bevel=0.12)
            box(counter, (sx * 10.5, y - 0.06, zf + 2.6), (8.4, 0.12, 1.8))
    # Pickup window: steel counter jutting out with three order boxes waiting.
    # Back edge ends 0.05 inside the facade (z zf + 0.95) instead of flush with the piers (R18).
    block(counter, (0, 3.2, zf - 0.225), (9.6, 0.4, 2.35), bevel=0.1)
    for k, x in enumerate((-2.8, 0.0, 2.8)):
        block(boxes, (x, 4.1, zf - 0.3 + 0.15 * k), (1.8, 1.4, 1.6), bevel=0.12)
        block(brand, (x, 4.2, zf - 1.12 + 0.15 * k), (1.82, 0.35, 0.05), bevel=0.0)
    # Striped mini awning over the pickup window.
    for i in range(6):
        x = -4.5 + 1.5 * (i + 0.5)
        box(brand if i % 2 == 0 else walls, (x, 8.0, zf - 1.1), (1.5, 0.25, 2.6), rot=rot_x(-14), bevel=0.05)
    # Fascia: orange band with logo + letters, charcoal parapet cap.
    # Fascia y 8.5..12.05: its top stands 0.05 above the wall tops (12.0), never flush (R18).
    block(brand, (0, 10.275, zf + 0.3), (W + 0.4, 3.55, 1.4), bevel=0.2)
    # A viewer facing the -Z facade has +X on their LEFT: logo first (+X), then the letters.
    boom_logo(star, brand, letters, (11.6, 10.25, zf - 0.4), 2.1, facing="-z")
    block_text(letters, "BOOMDASH", (-2.6, 10.25, zf - 0.4), 0.4, 0.3)
    # Same fascia on the back (owner R17: the name reads from both sides). It is the exact
    # 180-degree yaw of the front about the building centre, so the lettering stays right-reading
    # in any mesh orientation.
    # Back fascia: same height; it starts 0.05 INSIDE the back wall (z 7.05) so no face is flush.
    block(brand, (0, 10.275, -zf - 0.275), (W + 0.4, 3.55, 1.35), bevel=0.2)
    boom_logo(star, brand, letters, (-11.6, 10.25, -zf + 0.4), 2.1, facing="+z")
    block_text(letters, "BOOMDASH", (2.6, 10.25, -zf + 0.4), 0.4, 0.3, facing="+z")
    for sx in (-1, 1):
        block(trim, (sx * (W / 2 + 0.1), H + 0.35, 0), (0.8, 0.7, D + 0.4), bevel=0.12)
    for sz in (-1, 1):
        block(trim, (0, H + 0.35, sz * (D / 2 + 0.1)), (W + 0.4, 0.7, 0.8), bevel=0.12)
    block(roof, (0, H - 0.1, 0), (W - 0.6, 0.4, D - 0.6), bevel=0.05)
    # Side logos on both side walls (seen from the road at an angle; mirrored pair for R17).
    boom_logo(star, brand, letters, (-W / 2, 6.0, 1.0), 2.6, facing="-x", letter=False)
    boom_logo(star, brand, letters, (W / 2, 6.0, -1.0), 2.6, facing="+x", letter=False)
    # Rooftop vents.
    for x in (-2.0, 3.0):
        block(counter, (x, H + 0.6, 4.0), (2.4, 1.2, 2.0), bevel=0.15)
    return m


def build_scooter_rack():
    """Four-slot scooter rack (U loops) under an orange shelter roof, with a charging kiosk."""
    m = Model("A3_ScooterRack", "ground centre; slots run along X (3.2 apart, x = -4.8..4.8); scooters park nose +Z", budget=2500)
    steel = m.piece("Steel", STEEL, material="StudsSmall")
    roof = m.piece("Roof", BRAND)
    posts = m.piece("Posts", DARK_STEEL)
    kiosk = m.piece("Kiosk", WHITE)
    glow = m.piece("ChargeGlow", GLOW_GREEN, material="Neon")
    pad = m.piece("Pad", CONCRETE)
    block(pad, (0, 0.06, 0.8), (16.0, 0.12, 6.4), bevel=0.04)
    for k in range(4):
        x = -4.8 + 3.2 * k
        # U-loop wheel holder + a green charge light on each slot.
        bar(steel, (x - 0.45, 0.1, 2.2), (x - 0.45, 1.5, 2.2), 0.16)
        bar(steel, (x + 0.45, 0.1, 2.2), (x + 0.45, 1.5, 2.2), 0.16)
        bar(steel, (x - 0.45, 1.5, 2.2), (x + 0.45, 1.5, 2.2), 0.16)
        block(glow, (x, 1.75, 2.2), (0.5, 0.18, 0.2), bevel=0.04)
    bar(steel, (-6.4, 0.5, 2.2), (6.4, 0.5, 2.2), 0.2)
    # Shelter: four posts + gently sloped orange roof.
    for sx in (-1, 1):
        for z in (-1.6, 3.4):
            block(posts, (sx * 7.4, 3.4, z), (0.4, 6.8, 0.4), bevel=0.08)
    box(roof, (0, 7.0, 0.9), (16.0, 0.45, 6.2), rot=rot_x(-6), bevel=0.15)
    # Charging kiosk at the +X end.
    block(kiosk, (7.2, 1.6, 1.0), (1.4, 3.2, 1.2), bevel=0.15)
    block(glow, (7.2, 2.4, 0.38), (1.0, 0.8, 0.06), bevel=0.02)
    block(roof, (7.2, 3.3, 1.0), (1.5, 0.3, 1.3), bevel=0.06)
    return m


def build_scooter():
    """Cute delivery scooter: orange body + front shield, seat, headlight, branded box on the back."""
    m = Model("A3_Scooter", "ground centre between the wheels; nose faces -Z", budget=1500)
    body = m.piece("Body", BRAND, material="StudsSmall")
    tyres = m.piece("Tyres", TYRE)
    steel = m.piece("Steel", STEEL, material="StudsSmall")
    seat = m.piece("Seat", CHARCOAL, material="StudsSmall")
    box_p = m.piece("Box", WHITE, material="StudsSmall")
    star = m.piece("LogoStar", YELLOW, material="Smooth")
    light = m.piece("Light", LAMP_WARM, material="Neon")
    for z in (-1.55, 1.45):
        wheel(tyres, steel, (0, 0.62, z), 0.62, 0.45, segments=12)
    block(body, (0, 0.8, 0.0), (1.1, 0.35, 2.6), bevel=0.1)
    # Front shield + fender + steering column + handlebar with grips.
    box(body, (0, 1.8, -1.25), (1.2, 2.0, 0.35), rot=rot_x(12), bevel=0.12)
    ellipsoid(body, (0, 1.3, -1.55), (0.42, 0.25, 0.7), rings=4, segments=8)
    cylinder(steel, (0, 1.0, -1.55), (0, 3.15, -1.15), 0.12, segments=8)
    bar(steel, (-0.85, 3.2, -1.15), (0.85, 3.2, -1.15), 0.14)
    for sx in (-1, 1):
        cylinder(seat, (sx * 0.65, 3.2, -1.15), (sx * 0.95, 3.2, -1.15), 0.14, segments=6)
    revolve(light, [(0.0, -0.06), (0.24, -0.06), (0.24, 0.06), (0.0, 0.06)], center=(0, 2.85, -1.35), segments=10, rot=rot_x(90))
    # Rear cowl + seat.
    ellipsoid(body, (0, 1.35, 1.0), (0.62, 0.55, 1.05), rings=5, segments=10)
    block(seat, (0, 1.95, 0.75), (0.8, 0.3, 1.4), bevel=0.12)
    # Delivery box on a rack: logo on the back and both sides.
    block(steel, (0, 2.0, 1.75), (1.1, 0.15, 1.0), bevel=0.04)
    block(box_p, (0, 2.85, 1.75), (1.6, 1.55, 1.5), bevel=0.15)
    block(body, (0, 3.68, 1.75), (1.66, 0.18, 1.56), bevel=0.06)
    boom_logo(star, body, seat, (0, 2.85, 2.5), 0.6, facing="+z", letter=False, depth=0.08)
    for f, x in (("+x", 0.8), ("-x", -0.8)):
        boom_logo(star, body, seat, (x, 2.85, 1.75), 0.55, facing=f, letter=False, depth=0.08)
    return m


def build_gps_beacon():
    """GPS upgrade: lattice roof mast with a tilted dish and a giant red map pin over a glow ring."""
    m = Model("A3_GPSBeacon", "ground centre of the mast foot (stands on the HQ roof)", budget=3000)
    mast = m.piece("Mast", DARK_STEEL, material="StudsSmall")
    dish = m.piece("Dish", WHITE)
    pin = m.piece("Pin", TOY_RED)
    hole = m.piece("PinHole", WHITE, material="Smooth")
    ring = m.piece("GlowRing", (120, 220, 255), material="Neon")
    base = m.piece("Base", CONCRETE)
    block(base, (0, 0.25, 0), (3.0, 0.5, 3.0), bevel=0.12)
    truss(mast, (0, 0.5, 0), (0, 9.0, 0), 1.4, member=0.2, bays=4)
    # Dish on an arm, tilted up toward -Z.
    bar(mast, (0, 6.0, 0), (0, 6.0, -1.6), 0.25)
    revolve(dish, [(0.0, 0.0), (1.2, 0.15), (2.0, 0.6), (2.05, 0.75), (1.9, 0.7), (1.1, 0.3), (0.0, 0.2)], center=(0, 6.0, -1.9), segments=16, rot=rot_x(-55))
    cylinder(mast, (0, 6.0, -1.9), (0, 7.0, -2.6), 0.08, segments=6)
    # Platform + glow ring + giant map pin (teardrop pointing down).
    disc(mast, (0, 9.0, 0), 1.6, 0.3, segments=16)
    revolve(ring, [(1.2, 9.3), (1.55, 9.3), (1.55, 9.45), (1.2, 9.45)], segments=16, closed=True)
    revolve(pin, [(0.0, 9.6), (0.35, 10.3), (0.9, 11.2), (1.45, 12.2), (1.6, 12.9), (1.45, 13.6), (1.0, 14.15), (0.5, 14.4), (0.0, 14.45)], segments=16)
    for sz in (-1, 1):
        revolve(hole, [(0.0, -0.1), (0.55, -0.1), (0.55, 0.1), (0.0, 0.1)], center=(0, 12.95, sz * 1.62), segments=14, rot=rot_x(90))
    return m


def build_app_phone():
    """
    Mobile App upgrade: a giant phone on a kickstand showing the BoomDash app — orange header with
    the logo, three order cards with tiny nukes, a big green ORDER button and a red "1" badge.
    """
    m = Model("A3_AppPhone", "ground centre under the phone; screen faces -Z, leaning back 10 deg", budget=4000)
    shell = m.piece("Shell", CHARCOAL)
    screen = m.piece("Screen", (238, 244, 252), material="Smooth")
    brand = m.piece("Brand", BRAND, material="Smooth")
    cards = m.piece("Cards", WHITE, material="StudsSmall")
    button = m.piece("Button", (90, 200, 90), material="Smooth")
    letters = m.piece("Letters", WHITE, material="Smooth")
    star = m.piece("LogoStar", YELLOW, material="Smooth")
    badge = m.piece("Badge", TOY_RED, material="Neon")
    stand = m.piece("Stand", DARK_STEEL)
    noses = m.piece("NukeNoses", WHITE, material="Smooth")
    nukes = [m.piece("NukeRed", TOY_RED, material="Smooth"), m.piece("NukeMint", MINT, material="Smooth"), m.piece("NukeBlue", SKY_BLUE, material="Smooth")]
    tilt = rot_x(10)  # rot_x(+a) swings the phone's top toward +Z: it leans back on its kickstand
    W, H, T = 7.0, 12.5, 0.8
    cy = 0.9 + H / 2

    def p(x, y, z):
        """Phone-local point (origin at the phone centre, screen face at z = -T/2) -> model space."""
        v = tilt @ Vector((x, y, z))
        return (v.x, cy + v.y, v.z)

    box(shell, p(0, 0, 0), (W, H, T), rot=tilt, bevel=0.35)
    box(screen, p(0, 0.2, -T / 2 - 0.02), (W - 0.8, H - 1.6, 0.06), rot=tilt)
    # Header bar with logo + camera notch.
    box(brand, p(0, H / 2 - 1.9, -T / 2 - 0.08), (W - 0.8, 1.6, 0.08), rot=tilt)
    box(shell, p(0, H / 2 - 0.45, -T / 2 - 0.05), (1.4, 0.3, 0.06), rot=tilt)
    # Order cards: white tile, a tiny nuke icon, two text bars.
    for i in range(3):
        y = H / 2 - 3.6 - 1.75 * i
        box(cards, p(0, y, -T / 2 - 0.1), (W - 1.4, 1.45, 0.12), rot=tilt, bevel=0.06)
        nx, ny, nz = p(2.2, y - 0.45, -T / 2 - 0.25)  # viewer's left (+X)
        tiny_nuke(nukes[i], noses, None, (nx, ny, nz), height=0.95, radius=0.26, segments=8)
        box(screen, p(-0.4, y + 0.25, -T / 2 - 0.2), (3.0, 0.25, 0.04), rot=tilt)
        box(brand, p(0.0, y - 0.25, -T / 2 - 0.2), (2.2, 0.25, 0.04), rot=tilt)
    # Big ORDER button.
    box(button, p(0, -H / 2 + 1.5, -T / 2 - 0.12), (W - 1.6, 1.3, 0.16), rot=tilt, bevel=0.1)
    # The letters are built upright, then tilted with the phone via a temporary transform.
    _tilted_text(letters, "ORDER", p(0, -H / 2 + 1.5, -T / 2 - 0.2), 0.14, 0.06, tilt)
    # Logo in the header (built upright then tilted the same way).
    hx, hy, hz = p(2.3, H / 2 - 1.9, -T / 2 - 0.12)
    _tilted_logo(star, brand, letters, (hx, hy, hz), 0.65, tilt)
    # Notification badge on the top-right corner.
    bx, by, bz = p(-(W / 2 - 0.3), H / 2 - 0.3, -T / 2 - 0.2)  # viewer's top-right
    ellipsoid(badge, (bx, by, bz), (0.6, 0.6, 0.3), rings=5, segments=10)
    # Kickstand + feet.
    bar(stand, p(0, -H / 2 + 2.0, T / 2), (0, 0.2, 2.6), 0.5)
    block(stand, (0, 0.25, 0.4), (W - 1.0, 0.5, 2.0), bevel=0.15)
    return m


def _transform_new_verts(piece, before, rot, pivot):
    """Rotate every vertex added to `piece` since `before` (vertex count) by `rot` about `pivot`."""
    from snkit.core import br, rb

    piece.bm.verts.ensure_lookup_table()
    pv = Vector(pivot)
    for v in piece.bm.verts[before:]:
        p = Vector(br(v.co))
        q = rot @ (p - pv) + pv
        v.co = rb(tuple(q))


def _tilted_text(piece, text, center, cell, depth, rot):
    """block_text built upright at `center`, then rotated by `rot` about that centre."""
    piece.bm.verts.ensure_lookup_table()
    before = len(piece.bm.verts)
    block_text(piece, text, center, cell, depth, bevel=0.0)
    _transform_new_verts(piece, before, rot, center)


def _tilted_logo(star, disc_piece, ink, center, radius, rot):
    """boom_logo built upright at `center` (facing -Z), then rotated by `rot` about that centre."""
    counts = [len(p.bm.verts) for p in (star, disc_piece, ink)]
    boom_logo(star, disc_piece, ink, center, radius, facing="-z", depth=0.08)
    for p, before in zip((star, disc_piece, ink), counts):
        _transform_new_verts(p, before, rot, center)


# ------------------------------------------------------------------------------------------------
# Drivable vehicle kit (owner R56 "trucks drive in and out"). Shared by area03/04/06/08 vehicles.
#
# Runtime contract (the client drives a vehicle model as one unit, see V1-vehicles' VehicleFx):
#   * One wheel piece PER AXLE (`TyresF` / `TyresM` / `TyresR`, mine cart `WheelsF` / `WheelsR`)
#     holding BOTH wheels of that axle, mirrored left/right, so the piece's bounding-box centre is
#     exactly the axle point (0, radius, axle z). Matching `HubsF` / `HubsM` / `HubsR` (STEEL) sit
#     on the outer tyre faces with a point-symmetric spoke cross, so the bbox centre is the same
#     axle point and the spin reads (a plain disc would look static). The client spins every piece
#     whose name starts with Tyres / Hubs / Wheels about its own bbox centre's X axis.
#   * `BrakeLights` (Smooth TOY_RED, client swaps to Neon while braking), `IndicatorL` (-X side) and
#     `IndicatorR` (+X side) amber Smooth lamps at the front AND rear corners (client blinks them).
#   * `Cargo1..N`: one single-colour piece per parcel / crate, modelled where it sits when loaded.
# ------------------------------------------------------------------------------------------------

AMBER = (255, 178, 36)  # turn-signal amber: yellower than BoomDash ORANGE so it reads on the van


def axle_wheels(tyres, hubs, x_c, z, radius, width, segments=16, hub_style="rim"):
    """
    One axle's two toy wheels (axle along X) into the axle's `tyres` piece, plus their hub caps
    into the axle's `hubs` piece, mirrored so BOTH pieces' bbox centres sit on (0, radius, z).

    x_c:       distance from the vehicle centre line to each tyre's mid-plane (wheels at +-x_c)
    z:         axle z (Roblox space, front = -Z)
    radius:    tyre radius; the tyre touches the ground (y = 0) and the axle is at y = radius
    width:     tyre width along X
    segments:  tyre facets; MUST be a multiple of 4 so the polygon reaches +-radius on Y and Z
               (otherwise the bbox would be smaller on one axis — still centred, but not round)
    hub_style: "rim"   = steel ring + 4-spoke cross + centre boss (trucks, vans, forklift)
               "cross" = small 4-spoke cross + boss only (mine cart, tiny wheels)

    Why point-symmetric: the client rotates the piece about its bbox centre, so any detail that
    is not mirrored through the axle (5 spokes, a valve, a logo) would shift the centre and make
    the wheel wobble. A 4-spoke cross, a ring and a boss are all symmetric under 180 deg.

    Example:
        tf = m.piece("TyresF", TYRE); hf = m.piece("HubsF", STEEL, material="StudsSmall")
        axle_wheels(tf, hf, 1.9, -5.4, 1.0, 0.8)   # front axle of A6_DeliveryTruck
    """
    assert segments % 4 == 0, "tyre segments must be a multiple of 4 (bbox reaches +-radius)"
    w = width / 2
    shoulder = min(0.22, radius * 0.2)
    tyre_profile = [
        (0.0, -w),
        (radius - shoulder, -w),
        (radius, -w + shoulder),
        (radius, w - shoulder),
        (radius - shoulder, w),
        (0.0, w),
    ]
    small = hub_style == "cross"
    embed = 0.03 if small else 0.06  # hub parts start this far INSIDE the tyre face (no coplanar faces)
    ring_out, ring_in = 0.66 * radius, 0.52 * radius
    reach = 0.62 * radius if small else ring_out  # spoke half-length (spokes run into the ring)
    spoke_w = max(0.1 if small else 0.12, 0.18 * radius)
    boss_r = 0.26 * radius
    # Proud heights above the tyre face: ring < spokes < boss, so no two hub faces share a plane.
    ring_top = w + 0.06
    spoke_top = w + (0.06 if small else 0.09)
    boss_top = w + (0.09 if small else 0.14)
    for sx in (-1, 1):
        cx = sx * x_c
        centre = (cx, radius, z)
        revolve(tyres, tyre_profile, center=centre, segments=segments, rot=rot_z(90))
        # rot_z(-90 * sx) maps the revolve profile's local +Y onto the OUTWARD axle direction.
        outward = rot_z(-90 * sx)
        revolve(hubs, [(0.0, w - embed), (boss_r, w - embed), (boss_r, boss_top), (0.0, boss_top)], center=centre, segments=12, rot=outward)
        if not small:
            revolve(
                hubs,
                [(ring_in, w - embed), (ring_out, w - embed), (ring_out, ring_top), (ring_in, ring_top)],
                center=centre,
                segments=12,
                closed=True,
                rot=outward,
            )
        depth = spoke_top - (w - embed)
        mid_x = cx + sx * ((w - embed) + depth / 2)
        box(hubs, (mid_x, radius, z), (depth, 2 * reach, spoke_w))  # vertical spoke
        box(hubs, (mid_x, radius, z), (depth, spoke_w, 2 * reach))  # horizontal spoke


def toy_parcel(piece, center, size, yaw=0.0, tape=True):
    """
    Single-colour cardboard parcel / crate (one `CargoN` piece): bevelled block + a slightly raised
    tape band wrapping it across X (same colour, reads through shading). `center` is the parcel's
    centre; build it where it sits when the vehicle is loaded. yaw (deg) turns it about +Y.

    Example: toy_parcel(m.piece("Cargo1", KRAFT), (0, 6.83, -0.45), (2.0, 1.0, 1.7))
    """
    rot = rot_y(yaw) if yaw else None
    block(piece, center, size, bevel=0.12, rot=rot)
    if tape:
        box(piece, center, (size[0] + 0.04, size[1] + 0.04, 0.34), rot=rot)


def build_delivery_van():
    """Boxy branded delivery van: orange cargo box with white stripe + logos, cab with headlight
    eyes and grille smile, chunky wheels, and a big pocket-nuke mascot on the roof.

    R56 drivable split: per-axle TyresF/TyresR + HubsF/HubsR (spoked caps), BrakeLights (Smooth,
    client -> Neon when braking), IndicatorL/R amber corner lamps, a low roof rail (Bumpers) and
    three BoomDash parcels Cargo1..Cargo3 on the roof around the mascot plinth."""
    m = Model(
        "A3_DeliveryVan",
        "ground centre; cab faces -Z; mascot top at y ~ 10; axles z -3.2 / 3.4, wheel r 1.3; roof top y 6.35",
        budget=4000,
    )
    body = m.piece("Body", BRAND)
    white = m.piece("White", WHITE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.3)
    dark = m.piece("Bumpers", CHARCOAL)
    lights = m.piece("Headlights", LAMP_WARM, material="Neon")
    tail = m.piece("BrakeLights", TOY_RED, material="Smooth")
    ind_l = m.piece("IndicatorL", AMBER, material="Smooth")
    ind_r = m.piece("IndicatorR", AMBER, material="Smooth")
    star = m.piece("LogoStar", YELLOW, material="Smooth")
    nuke = m.piece("NukeBody", MINT, material="StudsSmall")
    core = m.piece("NukeCore", GLOW_GREEN, material="Neon")
    r = 1.3
    for suffix, z in (("F", -3.2), ("R", 3.4)):
        axle_wheels(m.piece("Tyres" + suffix, TYRE), m.piece("Hubs" + suffix, STEEL, material="StudsSmall"), 2.65, z, r, 1.1)
    # Cab (front, lower) + cargo box (back, tall).
    block(body, (0, 2.3, -3.4), (5.4, 2.6, 4.0), bevel=0.45, segments=2)
    block(body, (0, 4.1, -2.6), (5.2, 1.6, 2.6), bevel=0.4, segments=2)
    block(body, (0, 3.6, 2.0), (5.6, 5.0, 7.4), bevel=0.4, segments=2)
    block(white, (0, 6.2, 2.0), (5.7, 0.3, 7.5), bevel=0.08)
    # White stripe + logos along both sides of the cargo box.
    for sx in (-1, 1):
        block(white, (sx * 2.82, 2.4, 2.0), (0.1, 0.9, 7.3), bevel=0.03)
        boom_logo(star, body, white, (sx * 2.82, 4.2, 2.0), 1.4, facing="+x" if sx > 0 else "-x", letter=False, depth=0.12)
    boom_logo(star, body, white, (0, 3.8, 5.72), 1.3, facing="+z", letter=False, depth=0.12)
    # Windows: windshield + side cab windows.
    box(glass, (0, 4.15, -3.92), (4.4, 1.2, 0.1), rot=rot_x(8))  # leans back
    for sx in (-1, 1):
        block(glass, (sx * 2.62, 4.1, -2.7), (0.1, 1.1, 1.9), bevel=0.03)
    # Face: headlights, grille smile, bumpers.
    for sx in (-1, 1):
        revolve(lights, [(0.0, -0.08), (0.5, -0.08), (0.5, 0.08), (0.0, 0.08)], center=(sx * 1.65, 2.6, -5.42), segments=12, rot=rot_x(90))
        block(tail, (sx * 2.2, 2.2, 5.72), (0.7, 0.9, 0.12), bevel=0.05)
        # Turn signals: a small amber lamp low on each front corner of the cab face (below the
        # headlight, outside the grille smile) and one above each brake light on the cargo box back.
        ind = ind_r if sx > 0 else ind_l
        block(ind, (sx * 1.95, 1.72, -5.43), (0.5, 0.34, 0.12), bevel=0.05)
        block(ind, (sx * 2.2, 3.0, 5.72), (0.7, 0.45, 0.12), bevel=0.05)
    pts_o, pts_i = [], []
    for k in range(9):
        a = math.radians(200 + 140 * k / 8)
        pts_o.append((1.1 * math.cos(a), 2.25 + 0.65 * math.sin(a), -5.44))
        pts_i.append((0.75 * math.cos(a), 2.25 + 0.38 * math.sin(a), -5.44))
    prism(dark, pts_o + list(reversed(pts_i)), (0, 0, 1), 0.1)
    for z in (-5.45, 5.75):
        block(dark, (0, 1.05, z), (5.6, 0.6, 0.6), bevel=0.2)
    # Roof mascot nuke on a little plinth.
    block(dark, (0, 6.5, 2.0), (2.2, 0.35, 2.2), bevel=0.08)
    mini_nuke(nuke, white, dark, core, (0, 6.65, 2.0), length=3.4, radius=0.85)
    # Low roof rail (charcoal, in Bumpers): side rails on 3 posts each + front / rear cross bars that
    # butt between the side rails (thinner, so no top faces share a plane). Roof top y = 6.35.
    roof = 6.35
    rail_y = roof + 0.42
    for sx in (-1, 1):
        x = sx * 2.5
        bar(dark, (x, rail_y, -1.6), (x, rail_y, 5.55), 0.18)
        for z in (-1.45, 2.0, 5.4):
            bar(dark, (x, roof - 0.05, z), (x, rail_y, z), 0.14)
    for z in (-1.6, 5.5):
        bar(dark, (-2.41, rail_y, z), (2.41, rail_y, z), 0.15)
    # BoomDash parcels (kraft cardboard), one piece each: one on the front of the cargo-box roof,
    # two side by side behind the mascot. Mascot fins reach z 0.85 .. 3.15, |x| <= 1.15.
    sink = 0.02  # parcels sit 0.02 into the roof cap (no coplanar faces with the roof top)
    toy_parcel(m.piece("Cargo1", KRAFT), (0.0, roof - sink + 0.5, -0.45), (2.0, 1.0, 1.7), yaw=3)
    toy_parcel(m.piece("Cargo2", KRAFT), (-1.07, roof - sink + 0.5, 4.35), (1.9, 1.0, 1.85), yaw=-3)
    toy_parcel(m.piece("Cargo3", KRAFT), (1.1, roof - sink + 0.55, 4.4), (1.8, 1.1, 1.6), yaw=4)
    return m


def build_parking_lot():
    """
    Parking Lot upgrade (slot-origin pivot; paints the asphalt pad from A3_Lot): two stall bays,
    wheel stops, a hazard-striped loading zone and a blue P sign (its two lamps are A3_Lamp
    instances placed by the layout).
    """
    m = Model("A3_ParkingLot", SLOT_PIVOT, budget=2500)
    lines = m.piece("Lines", WHITE)
    stops = m.piece("WheelStops", CONCRETE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    sign = m.piece("Sign", DEEP_BLUE)
    letters = m.piece("Letters", WHITE, material="Smooth")
    posts = m.piece("Posts", DARK_STEEL)
    y = LOT_TOP + 0.08
    for x in (35.6, 43.3, 51.0):
        block(lines, (x, y, 29.5), (0.35, 0.06, 13.0), bevel=0.0)
    block(lines, (43.3, y, 36.3), (15.75, 0.06, 0.35), bevel=0.0)
    for x in (39.45, 47.15):
        block(stops, (x, LOT_TOP + 0.25, 35.7), (4.0, 0.5, 0.6), bevel=0.12)
    hazard_floor(yellow, black, (43.3, LOT_TOP + 0.09, 40.0), (15.0, 4.0), 0.06, stripe=1.2)
    # P sign on a pole.
    cylinder(posts, (51.0, LOT_TOP, 42.5), (51.0, LOT_TOP + 7.0, 42.5), 0.15, segments=8)
    block(sign, (51.0, LOT_TOP + 7.4, 42.3), (2.4, 2.4, 0.25), bevel=0.15)
    sign_text(letters, "P", (51.0, LOT_TOP + 7.4, 42.3), 0.24, 0.08, 0.125)  # both faces (R17)
    return m


def build_dispatcher():
    """
    Dispatcher (Area 3 Manager): BoomDash crew member in an orange polo + cap with a headset,
    holding a clipboard, standing beside a dispatch desk whose screen shows a route map.

    Animated NPC (owner R30): the figure is split into rig pieces (Torso*/Head*/ArmL*/ArmR*/LegL*/
    LegR*, see models/_npc_rig.py) so the client ManagerController can walk him between his desk
    and the lane, swing his limbs, wave (raises the free right arm) and tap the desk. The desk
    (Desk, DeskTrim, Screen, Route) stays a static prop: its dark trim is its own piece so the
    headset can ride the head, its stripe uses the Screen colour and the map's end star the Route
    glow (keeps the model at 24 pieces).
    """
    from models._npc_rig import a1_bones, rig_split

    m = Model("A3_Dispatcher", "character's ground centre; faces -Z; desk at +X", budget=3500)
    shirt = m.piece("Shirt", BRAND, material="StudsSmall")
    pants = m.piece("Pants", (60, 70, 96), material="StudsSmall")
    shoes = m.piece("Shoes", CHARCOAL, material="StudsSmall")
    skin = m.piece("Skin", SKIN, material="Smooth")
    face = m.piece("Face", (40, 36, 46), material="Smooth")
    cheeks = m.piece("Cheeks", (255, 150, 150), material="Smooth")
    hair = m.piece("Hair", (110, 70, 40), material="StudsSmall")
    gear = m.piece("Headset", DARK_STEEL, material="StudsSmall")
    star = m.piece("LogoStar", YELLOW, material="Smooth")
    desk = m.piece("Desk", WHITE)
    screen = m.piece("Screen", SKY_BLUE, material="Smooth")
    route = m.piece("Route", GLOW_GREEN, material="Neon")
    clip = m.piece("Clipboard", (160, 110, 64), material="StudsSmall")
    desk_dark = m.piece("DeskTrim", DARK_STEEL, material="StudsSmall")
    a = toy_figure(
        {"shoes": shoes, "legs": pants, "torso": shirt, "arms": shirt, "skin": skin, "face": face, "cheeks": cheeks},
        left_arm=(15.0, 50.0),
        right_arm=(25.0, 0.0),
    )
    hc = a["head"]
    hw, hh, hd = a["head_size"]
    # Hair under the cap + cap with a front brim and a star badge.
    block(hair, (0, hc[1] + 0.3, 0.25), (hw + 0.1, 1.0, hd - 0.3), bevel=0.25)
    block(shirt, (0, hc[1] + hh / 2 + 0.05, 0.05), (hw + 0.16, 0.55, hd + 0.1), bevel=0.2)
    block(shirt, (0, hc[1] + hh / 2 - 0.15, -hd / 2 - 0.45), (hw - 0.2, 0.14, 0.9), bevel=0.05)
    boom_logo(star, shirt, face, (0, hc[1] + hh / 2 + 0.05, -hd / 2 - 0.06), 0.3, facing="-z", letter=False, depth=0.05)
    # Headset: band over the cap, ear cups, mic boom.
    for sx in (-1, 1):
        revolve(gear, [(0.0, -0.18), (0.42, -0.18), (0.42, 0.18), (0.0, 0.18)], center=(sx * (hw / 2 + 0.15), hc[1], 0), segments=10, rot=rot_z(90))
    bar(gear, (-(hw / 2 + 0.15), hc[1] + 0.3, 0), (-(hw / 2 + 0.15), hc[1] + hh / 2 + 0.4, 0), 0.14)
    bar(gear, (hw / 2 + 0.15, hc[1] + 0.3, 0), (hw / 2 + 0.15, hc[1] + hh / 2 + 0.4, 0), 0.14)
    bar(gear, (-(hw / 2 + 0.15), hc[1] + hh / 2 + 0.4, 0), (hw / 2 + 0.15, hc[1] + hh / 2 + 0.4, 0), 0.14)
    bar(gear, (-(hw / 2 + 0.25), hc[1] - 0.1, -0.1), (-0.5, hc[1] - 0.55, -hd / 2 - 0.25), 0.1)
    ellipsoid(gear, (-0.45, hc[1] - 0.58, -hd / 2 - 0.28), (0.16, 0.13, 0.13), rings=4, segments=6)
    # Shirt logo + clipboard in the left hand.
    boom_logo(star, shirt, face, a["chest"], 0.42, facing="-z", letter=False, depth=0.05)
    lx, ly, lz = a["hands"]["left"]
    box(clip, (lx + 0.1, ly + 0.45, lz - 0.25), (1.0, 1.3, 0.1), rot=rot_x(-30), bevel=0.04)
    box(desk, (lx + 0.1, ly + 0.45, lz - 0.31), (0.85, 1.0, 0.04), rot=rot_x(-30))
    # Dispatch desk on his right: podium + a monitor showing a route map. The monitor group is
    # built upright, then leaned back 12 degrees about its centre.
    dx = 3.9
    block(desk, (dx, 1.75, -0.2), (2.6, 3.5, 2.0), bevel=0.2)
    block(screen, (dx, 1.0, -1.22), (2.62, 0.4, 0.06), bevel=0.0)
    block(desk_dark, (dx, 3.6, -0.2), (2.9, 0.25, 2.3), bevel=0.08)
    mon = (dx, 4.75, 0.2)
    counts = [len(p.bm.verts) for p in (desk_dark, screen, route)]
    block(desk_dark, mon, (2.6, 1.8, 0.25), bevel=0.1)
    box(screen, (dx, 4.75, 0.04), (2.2, 1.45, 0.06))
    for (ax, ay), (bx, by) in (((-0.8, -0.4), (-0.2, 0.1)), ((-0.2, 0.1), (0.4, -0.2)), ((0.4, -0.2), (0.8, 0.45))):
        bar(route, (dx + ax, 4.75 + ay, -0.04), (dx + bx, 4.75 + by, -0.04), 0.1)
    ellipsoid(route, (dx + 0.8, 5.2, -0.06), (0.15, 0.15, 0.08), rings=4, segments=6)
    for p, before in zip((desk_dark, screen, route), counts):
        _transform_new_verts(p, before, rot_x(12), mon)
    bar(desk_dark, (dx, 3.7, 0.4), (dx, 4.0, 0.3), 0.3)
    # Body-part pieces for the client NPC rig. The desk pieces never move; the clipboard rides
    # the left hand, the headset the head. reach 0.9 keeps the desk's white podium (score ~1.4
    # from the right hand) a static prop while the clipboard paper (~0.15) joins the left arm.
    rig_split(
        m,
        a1_bones(a),
        static=("DeskTrim", "Screen", "Route"),
        assign={"Clipboard": "ArmL", "Headset": "Head"},
        reach=0.9,
    )
    return m


BUILDERS = {
    "A3_Lot": build_lot,
    "A3_EntryArch": build_arch,
    "A3_Yard": build_yard,
    "A3_HQ": build_hq,
    "A3_ScooterRack": build_scooter_rack,
    "A3_Scooter": build_scooter,
    "A3_GPSBeacon": build_gps_beacon,
    "A3_AppPhone": build_app_phone,
    "A3_DeliveryVan": build_delivery_van,
    "A3_ParkingLot": build_parking_lot,
    "A3_Dispatcher": build_dispatcher,
    "A3_Lamp": build_lamp,
}
