"""
moon_area02.py — Moon Base area M2 "Cosmic Diner" models (W6 art-d12, owner R70; spec
2026-10-31-r69-moon-lucky-juice-design §2.2): a retro chrome + neon diner for alien customers,
with a walk-up counter, booths, a rocket jukebox and saucer-umbrella tables on a checkered patio.

    M2_Floor          moon-dust lot with a mint / white checkered patio, a dust path and craters  base
    M2_EntryArch      "COSMIC DINER" arch: chrome capsule posts, coral board, chrome letters      base
    M2_DinerHall      the retro diner building behind the counter (stadium plan, chrome + coral) base
    M2_DinerCounter   the producer: a coral + chrome walk-up counter with four stools and two     M2_DinerCounter
                      moon-rock nukes on cake stands
    M2_NeonSign       a rocket-shaped sign pole with a round "NUKES" board (both faces, R17)      M2_NeonSign
    M2_StarRegister   a sunny star-shaped cash register (on the counter)                         M2_StarRegister
    M2_BoothSeats     a retro booth: two curved coral benches round a mint table (placed 2x)     M2_BoothSeats
    M2_RocketJukebox  a rocket-shaped jukebox; its `Jukebox*` light bands pulse (WorldFx row)    M2_RocketJukebox
    M2_ShakeMachine   chrome milkshake machine with three candy shakes (on the counter)          M2_ShakeMachine
    M2_CraterTables   a round table + two stools under a flying-saucer umbrella (placed 4x)      M2_CraterTables
    M2_ZipZorp        the Manager: a three-eyed green alien waiter on roller skates carrying a   M2_ZipZorp
                      milkshake on a tray; R30 rig groups (tray rides ArmR)
    M2_LandingLights  a 12-stud row of four runway light posts (placed 2x along the path)        M2_LandingLights

Placement: src/shared/Config/Worlds/Moon/Layouts/Area02.luau (slot-local frame, docs/areas-art.md).
SLOT-ORIGIN model: M2_Floor (identity cf). Counter-top props (register, shake machine) share the
COUNTER pivot: ground centre of the counter, customers on -Z, counter top y = COUNTER_TOP. Every
other model is pivoted at its own ground centre with its front toward -Z.

WorldFx (rows in WorldFxConfig "-- Moon Base M1/M2"): `Jukebox*` light bands (soft pulsing light,
nothing moves); `Bulb*` star bulbs / runway globes (existing light row).
Shared helpers come from models/moon_area01.py.
"""

from __future__ import annotations

import math

from mathutils import Vector

from models._critter_kit import eyes, oriented_ellipsoid, smile, star, tube
from models.area01 import LOT_TOP, SLOT_PIVOT, sign_text, text_cells
from models.area04 import _hash
from models.moon_area01 import (
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
    SLOT_D,
    SLOT_W,
    STAR_GLOW,
    SUNNY,
    VIOLET,
    crater,
    moon_arch,
    moon_nuke,
    toon_biped,
    toon_bones,
)
from snkit.core import Model
from snkit.kit import block, disc
from snkit.shapes import cylinder, ellipsoid, extrude_outline, prism, revolve, ring_tube, rot_x, rot_y, rot_z

COUNTER_TOP = 3.2  # counter top above the counter pivot
COUNTER_PIVOT = "counter pivot: ground centre of the counter; customers on -Z; counter top y = 3.2"
TILE_WHITE = (240, 242, 250)
CREAM_TOP = (255, 246, 230)
CHERRY = (236, 50, 70)

# Patio (checkered tiles) extent in slot space and tile size.
PATIO_X = 22.0
PATIO_Z0, PATIO_Z1 = 18.0, 50.0
TILE = 4.0


# ------------------------------------------------------------------------------------------------
# Base
# ------------------------------------------------------------------------------------------------

FLOOR_CRATERS = ((-34.0, 34.0, 2.4), (36.0, 33.0, 2.2), (-44.0, 58.0, 2.0), (30.0, 62.0, 2.6), (-30.0, 20.0, 1.6))


def build_floor():
    """
    Moon-dust lot (slot pivot): ground plate, a mint / white checkered patio (+0.08, tiles butt edge
    to edge on straight seams), a dust path stub from the arch (+0.06) and a few raised craters.
    """
    m = Model("M2_Floor", SLOT_PIVOT, budget=2200)
    ground = m.piece("Ground", MOON_GROUND, material="StudsLarge")
    path = m.piece("Path", MOON_DUST)
    mint = m.piece("TilesMint", MINT_C)
    white = m.piece("TilesWhite", TILE_WHITE)
    rims = m.piece("CraterRims", (186, 180, 214))
    bowls = m.piece("CraterBowls", MOON_DARK)
    block(ground, (0, LOT_TOP / 2, SLOT_D / 2), (SLOT_W, LOT_TOP, SLOT_D), bevel=0.1)
    extrude_outline(path, [(-4.5, 0.0), (4.5, 0.0), (4.5, PATIO_Z0 + 0.5), (-4.5, PATIO_Z0 + 0.5)], LOT_TOP - 0.04, LOT_TOP + 0.06)
    nx = int(round(2 * PATIO_X / TILE))
    nz = int(round((PATIO_Z1 - PATIO_Z0) / TILE))
    for ix in range(nx):
        for iz in range(nz):
            x = -PATIO_X + TILE * (ix + 0.5)
            z = PATIO_Z0 + TILE * (iz + 0.5)
            piece = mint if (ix + iz) % 2 == 0 else white
            block(piece, (x, LOT_TOP + 0.02, z), (TILE, 0.12, TILE), bevel=0.0)
    for x, z, r in FLOOR_CRATERS:
        crater(rims, bowls, (x, LOT_TOP, z), r, segments=12)
    return m


def build_arch():
    """COSMIC DINER arch: chrome capsule posts with sunny / mint bands, a coral board, chrome letters."""
    return moon_arch("M2_EntryArch", ["COSMIC", "DINER"], band_a=SUNNY, band_b=MINT_C, board=CORAL_C, letters=CHROME, planet=MINT_C, ring=SUNNY)


def build_diner_hall():
    """
    The retro diner building (pivot = ground centre of the building, front -Z): a stadium plan
    (straight 28-stud middle + round ends, 10 deep, 7 high) of chrome walls on a navy plinth, a proud
    coral stripe, a band of navy windows across the front, a round-porthole door, an overhanging
    rounded roof with a mint trim and a little chrome rocket fin on top. Stands behind the counter.
    """
    m = Model("M2_DinerHall", "ground centre of the diner; front -Z; 38 x 10 footprint", budget=2600)
    wall = m.piece("Walls", CHROME)
    plinth = m.piece("Plinth", NAVY)
    stripe = m.piece("Stripe", CORAL_C)
    glass = m.piece("Windows", (70, 90, 170), material="Glass", transparency=0.1)
    roof = m.piece("Roof", CHROME_SHADE)
    trim = m.piece("RoofTrim", MINT_C)
    door = m.piece("Door", NAVY, material="Smooth")
    fin = m.piece("Fin", CORAL_C)
    half = 14.0  # half length of the straight middle
    r = 5.0  # end radius

    def stadium(rad, y0, y1, piece, segs=10):
        """
        Stadium solid (a straight middle of length 2 * half with half-disc ends of radius `rad`)
        from y0 to y1, as ONE convex outline: no internal faces, so stacked stadiums (wall,
        stripe, roof, trim) never share a hidden coplanar end face (R18).
        """
        outline = []
        for sx in (1, -1):
            for i in range(segs + 1):
                a = math.radians(-90 + 180 * i / segs)
                # sx = 1: the +X cap from z -rad round to z +rad; sx = -1: the -X cap back again.
                outline.append((sx * (half + rad * math.cos(a)), sx * rad * math.sin(a)))
        extrude_outline(piece, outline, y0, y1)

    stadium(r + 0.3, 0.0, 0.8, plinth)
    stadium(r, 0.8, 7.0, wall)
    stadium(r + 0.12, 1.6, 2.4, stripe)
    stadium(r + 0.8, 7.0, 7.7, roof)
    stadium(r + 0.92, 7.25, 7.55, trim)
    # Window band across the straight front (proud of the wall face by 0.06), split by the door.
    for x0, x1 in ((-13.0, -2.4), (2.4, 13.0)):
        block(glass, ((x0 + x1) / 2, 4.4, -r - 0.05), (x1 - x0, 2.6, 0.12), bevel=0.0)
    block(door, (0, 3.2, -r - 0.06), (3.2, 4.8, 0.14), bevel=0.04)
    ring_tube(roof, (0, 4.2, -r - 0.18), 0.7, 0.22, 0.14, segments=12, axis="Z")
    # Rocket fin on the roof (a tall rounded triangle, both faces identical).
    prism(fin, [(-1.4, 7.7, 0.0), (1.6, 7.7, 0.0), (0.4, 11.0, 0.0), (-0.6, 10.6, 0.0)], (0, 0, 1), 0.5)
    return m


# ------------------------------------------------------------------------------------------------
# Counter + builds
# ------------------------------------------------------------------------------------------------


def build_diner_counter():
    """
    The Cosmic Diner producer: a 14-wide walk-up counter (coral front with two proud chrome bands, a
    chrome top with a rounded front lip), four chrome stools with coral cushions in front of it and
    two moon-rock nukes on chrome cake stands (each with its own small Neon band, R19).
    """
    m = Model("M2_DinerCounter", COUNTER_PIVOT, budget=3000)
    front = m.piece("Front", CORAL_C)
    chrome = m.piece("Chrome", CHROME)
    lip = m.piece("Lip", CHROME_SHADE)
    cushions = m.piece("Cushions", CORAL_C, material="Smooth")
    rock = m.piece("MoonRock", (196, 186, 226), material="StudsSmall")
    fins = m.piece("MoonFins", MINT_C, material="StudsSmall")
    block(front, (0, (COUNTER_TOP - 0.3) / 2, 0), (14.0, COUNTER_TOP - 0.3, 2.4), bevel=0.2)
    for y in (0.7, 2.0):
        block(chrome, (0, y, -1.24), (13.6, 0.3, 0.1), bevel=0.03)
    block(chrome, (0, COUNTER_TOP - 0.15, 0.1), (14.4, 0.3, 2.9), bevel=0.1)
    cylinder(lip, (-7.25, COUNTER_TOP - 0.15, -1.38), (7.25, COUNTER_TOP - 0.15, -1.38), 0.2, segments=8)
    # Stools in front (z -2.6): chrome stem + base disc + coral cushion.
    for x in (-4.8, -1.6, 1.6, 4.8):
        disc(chrome, (x, 0.0, -2.7), 0.55, 0.15, segments=10, bevel=0.04)
        cylinder(chrome, (x, 0.15, -2.7), (x, 1.9, -2.7), 0.12, segments=6)
        disc(cushions, (x, 1.9, -2.7), 0.7, 0.4, segments=12, bevel=0.15)
    # Two moon-rock nukes on cake stands (centre-left and centre-right of the top).
    for k, x in enumerate((-1.6, 1.4)):
        disc(lip, (x, COUNTER_TOP, 0.3), 0.25, 0.7, segments=8, bevel=0.05)
        disc(lip, (x, COUNTER_TOP + 0.7, 0.3), 0.85, 0.12, segments=12, bevel=0.04)
        band = m.piece(f"MoonBand{'AB'[k]}", (140, 255, 210), material="Neon")
        moon_nuke(rock, band, fins, (x, COUNTER_TOP + 0.82, 0.3), height=1.8, segments=8)
    return m


def build_neon_sign():
    """
    The diner's rocket sign (pivot = ground centre of the pole; rocket pieces are named Sign* so the
    WorldFx `Rocket` idle-shake row never moves them off the ring, R25): a chrome pole on a navy base holding
    a round navy board with "NUKES" in mint block letters on BOTH faces (R17), a sunny ring rim with
    small Neon star bulbs (one piece per face so each stays a small R19 accent), and a little chrome
    rocket (coral nose + fins) standing on top of the ring. ~19 tall.
    """
    m = Model("M2_NeonSign", "ground centre of the pole; board faces -Z, reads from both sides", budget=2600)
    pole = m.piece("Pole", CHROME_SHADE)
    base = m.piece("Base", NAVY)
    body = m.piece("SignRocket", CHROME)
    nose = m.piece("SignNose", CORAL_C)
    board = m.piece("Board", NAVY)
    ring = m.piece("BoardRing", SUNNY)
    letters = m.piece("Letters", MINT_C, material="Smooth")
    disc(base, (0, 0, 0), 1.4, 0.6, segments=12, bevel=0.15)
    by, br = 10.0, 3.0  # board centre height + radius
    cylinder(pole, (0, 0.6, 0), (0, by - br + 0.2, 0), 0.32, segments=8)
    # Round board (a disc along Z) with a proud sunny ring rim.
    cylinder(board, (0, by, -0.45), (0, by, 0.45), br, segments=20)
    ring_tube(ring, (0, by, 0), br + 0.12, 0.36, 1.1, segments=20, axis="Z")
    cell = min(0.36, 4.6 / text_cells("NUKES"))
    sign_text(letters, "NUKES", (0, by, 0), cell, 0.2, 0.45)
    for side, sz in (("F", -1), ("B", 1)):
        bulbs = m.piece(f"Bulb{side}", STAR_GLOW, material="Neon")
        for k in range(8):
            a = 2 * math.pi * (k + 0.5) / 8
            star(bulbs, ((br + 0.12) * math.cos(a), by + (br + 0.12) * math.sin(a), sz * 0.62), 0.24, 0.08, normal=(0, 0, sz))
    # Little rocket standing on the top of the ring (base sinks 0.1 into the ring: same model).
    ry = by + br + 0.2
    sc = 0.75
    revolve(body, [(0.0, 0.0), (1.0 * sc, 0.0), (1.25 * sc, 1.2 * sc), (1.25 * sc, 5.0 * sc), (1.0 * sc, 6.0 * sc)], center=(0, ry, 0), segments=12)
    revolve(nose, [(1.0 * sc, 6.0 * sc), (0.6 * sc, 7.2 * sc), (0.0, 7.8 * sc)], center=(0, ry, 0), segments=12)
    for i in range(3):
        a = math.radians(90 + 120 * i)
        n = (math.cos(a), 0.0, math.sin(a))
        prism(nose, [(0.9 * sc * n[0], ry + 0.2, 0.9 * sc * n[2]), (2.0 * sc * n[0], ry, 2.0 * sc * n[2]), (2.0 * sc * n[0], ry + 1.0 * sc, 2.0 * sc * n[2]), (1.1 * sc * n[0], ry + 2.4 * sc, 1.1 * sc * n[2])], (-n[2], 0.0, n[0]), 0.22)
    return m


def build_star_register():
    """A sunny star-shaped cash register (counter top): star body, navy screen, mint keys, coral tab."""
    m = Model("M2_StarRegister", "bottom centre (on the counter top); front -Z", budget=900)
    body = m.piece("Body", SUNNY)
    screen = m.piece("Screen", NAVY, material="Smooth")
    keys = m.piece("Keys", MINT_C, material="Smooth")
    tab = m.piece("Tab", CORAL_C, material="Smooth")
    block(body, (0, 0.35, 0), (1.8, 0.7, 1.3), bevel=0.15)
    star(body, (0, 1.65, 0.1), 1.0, 0.5, normal=(0, 0, -1))
    oriented_ellipsoid(screen, (0, 1.6, -0.17), (0.45, 0.32, 0.04), normal=(0, 0, -1), rings=4, segments=10)
    for i in range(3):
        for j in range(2):
            block(keys, (-0.5 + 0.5 * i, 0.55 + 0.2 * j, -0.68), (0.32, 0.12, 0.08), bevel=0.02)
    block(tab, (0.0, 2.85, 0.1), (0.7, 0.4, 0.12), bevel=0.04)
    return m


def build_booth_seats():
    """
    A retro diner booth (pivot = table centre): two curved benches facing each other across a
    round mint table (chrome edge, chrome pedestal). Coral cushions, chrome bases, tall rounded
    coral backs with a chrome piping line.
    """
    m = Model("M2_BoothSeats", "ground centre of the table; benches at z +-2.4", budget=1500)
    cushion = m.piece("Cushions", CORAL_C)
    chrome = m.piece("Chrome", CHROME)
    piping = m.piece("Piping", CHROME_SHADE)
    table = m.piece("Table", MINT_C)
    disc(chrome, (0, 0, 0), 0.8, 0.15, segments=10, bevel=0.04)
    cylinder(chrome, (0, 0.15, 0), (0, 2.3, 0), 0.18, segments=8)
    disc(table, (0, 2.3, 0), 1.6, 0.25, segments=16, bevel=0.08)
    ring_tube(piping, (0, 2.42, 0), 1.62, 0.12, 0.2, segments=16, axis="Y")
    for sz in (-1, 1):
        z = sz * 2.5
        block(chrome, (0, 0.5, z), (4.0, 1.0, 1.5), bevel=0.15)
        block(cushion, (0, 1.25, z), (4.2, 0.5, 1.6), bevel=0.2)
        block(cushion, (0, 2.55, z + sz * 0.6), (4.2, 2.1, 0.5), bevel=0.2)
        cylinder(piping, (-2.15, 3.55, z + sz * 0.6), (2.15, 3.55, z + sz * 0.6), 0.14, segments=6)
    return m


def build_rocket_jukebox():
    """
    The Rocket Jukebox (pivot = ground centre, front -Z): a fat rounded rocket body (violet) on three
    coral fins, a chrome speaker grille + record window on the front, two arched light bands
    (`JukeboxLightsMint` / `JukeboxLightsSun`: the WorldFx Jukebox row pulses a soft light) and a
    chrome nose with a sunny star.
    """
    m = Model("M2_RocketJukebox", "ground centre of the jukebox; front -Z", budget=1800)
    body = m.piece("Body", VIOLET)
    fins = m.piece("Fins", CORAL_C)
    chrome = m.piece("Chrome", CHROME)
    grille = m.piece("Grille", NAVY, material="Smooth")
    record = m.piece("Record", INK_M, material="Smooth")
    mint = m.piece("JukeboxLightsMint", MINT_C, material="Neon")
    sun = m.piece("JukeboxLightsSun", SUNNY, material="Neon")
    revolve(body, [(0.0, 0.4), (1.4, 0.4), (1.7, 1.4), (1.7, 4.2), (1.3, 5.4), (0.0, 5.7)], center=(0, 0, 0), segments=14)
    revolve(chrome, [(1.25, 5.3), (0.8, 6.3), (0.0, 6.8)], center=(0, 0, 0), segments=12)
    star(chrome, (0, 7.25, 0), 0.45, 0.16, normal=(0, 0, -1))
    for i in range(3):
        a = math.radians(-90 + 120 * i + 60)
        n = (math.cos(a), 0.0, math.sin(a))
        prism(fins, [(1.5 * n[0], 0.0, 1.5 * n[2]), (2.4 * n[0], 0.0, 2.4 * n[2]), (1.6 * n[0], 2.0, 1.6 * n[2])], (-n[2], 0.0, n[0]), 0.3)
    # Front: speaker grille (a rounded navy plate with chrome bars) and a record window above it.
    block(grille, (0, 1.9, -1.72), (1.8, 1.2, 0.1), bevel=0.04)
    for k in range(4):
        block(chrome, (0, 1.5 + 0.27 * k, -1.8), (1.6, 0.08, 0.06), bevel=0.0)
    cylinder(record, (0, 3.5, -1.66), (0, 3.5, -1.78), 0.62, segments=14)
    ring_tube(chrome, (0, 3.5, -1.76), 0.7, 0.16, 0.14, segments=14, axis="Z")
    # Light bands: arcs over the front (mint outer, sunny inner), proud of the body.
    for piece, rad, lift in ((mint, 1.25, 0.0), (sun, 0.95, 0.0)):
        pts = []
        for k in range(9):
            a = math.radians(180 * k / 8)
            pts.append((rad * math.cos(a), 3.5 + rad * math.sin(a) + lift, -1.78 - 0.06))
        tube(piece, pts, 0.1, sides=5)
    return m


def build_shake_machine():
    """
    Milkshake machine (counter top, front -Z): a chrome base with a mint stripe, a tall back post with
    three mixer heads, and three candy milkshakes (coral, mint, violet glasses) with whipped cream and
    a cherry each.
    """
    m = Model("M2_ShakeMachine", "bottom centre (on the counter top); front -Z", budget=1600)
    chrome = m.piece("Chrome", CHROME)
    stripe = m.piece("Stripe", MINT_C)
    cream = m.piece("Cream", CREAM_TOP, material="Smooth")
    cherry = m.piece("Cherries", CHERRY, material="Smooth")
    block(chrome, (0, 0.25, 0), (3.0, 0.5, 1.2), bevel=0.12)
    block(stripe, (0, 0.25, -0.62), (2.8, 0.18, 0.06), bevel=0.0)
    block(chrome, (0, 1.6, 0.45), (2.8, 2.7, 0.3), bevel=0.1)
    for k, (x, colour) in enumerate(((-0.9, CORAL_C), (0.0, MINT_C), (0.9, VIOLET))):
        cylinder(chrome, (x, 2.9, 0.3), (x, 2.9, -0.15), 0.18, segments=6)
        cylinder(chrome, (x, 2.9, -0.15), (x, 2.2, -0.15), 0.05, segments=5)
        glass = m.piece(f"Shake{'ABC'[k]}", colour)
        revolve(glass, [(0.0, 0.0), (0.2, 0.0), (0.32, 1.0), (0.0, 1.0)], center=(x, 0.5, -0.15), segments=8)
        ellipsoid(cream, (x, 1.62, -0.15), (0.3, 0.22, 0.3), rings=4, segments=8)
        ellipsoid(cherry, (x, 1.92, -0.15), (0.1, 0.1, 0.1), rings=3, segments=6)
    return m


def build_crater_tables():
    """A round table with two stools under a flying-saucer umbrella (pivot = table centre)."""
    m = Model("M2_CraterTables", "ground centre of the table; stools at x +-1.9", budget=900)
    chrome = m.piece("Chrome", CHROME)
    top = m.piece("TableTop", SUNNY)
    seats = m.piece("Seats", VIOLET, material="Smooth")
    saucer = m.piece("Saucer", MINT_C)
    dome = m.piece("SaucerDome", (190, 230, 255), material="Glass", transparency=0.15)
    disc(chrome, (0, 0, 0), 0.7, 0.15, segments=10, bevel=0.04)
    cylinder(chrome, (0, 0.15, 0), (0, 2.2, 0), 0.14, segments=6)
    disc(top, (0, 2.2, 0), 1.3, 0.2, segments=14, bevel=0.07)
    for sx in (-1, 1):
        disc(chrome, (sx * 1.9, 0, 0), 0.4, 0.1, segments=8, bevel=0.03)
        cylinder(chrome, (sx * 1.9, 0.1, 0), (sx * 1.9, 1.3, 0), 0.1, segments=6)
        disc(seats, (sx * 1.9, 1.3, 0), 0.55, 0.3, segments=10, bevel=0.1)
    # Umbrella: pole up through the table, a saucer canopy with a glass dome on top.
    cylinder(chrome, (0, 2.4, 0), (0, 5.6, 0), 0.08, segments=6)
    revolve(saucer, [(0.0, 0.0), (2.6, 0.25), (2.9, 0.45), (2.4, 0.65), (0.0, 0.7)], center=(0, 5.4, 0), segments=16)
    ellipsoid(dome, (0, 6.1, 0), (0.9, 0.6, 0.9), rings=5, segments=12)
    return m


def build_zip_zorp():
    """
    Zip Zorp (M2 Manager, owner R30): a round green alien waiter with three big eyes, two bobbly
    antennae, a navy waiter vest with a coral bow tie, white gloves and roller skates (sunny wheels).
    His right hand carries a tray with a pink milkshake. R30 rig groups (vest + bow tie ride the
    Torso; antennae ride the Head; tray + shake ride ArmR; skates + wheels ride the legs).
    """
    from models._npc_rig import rig_split

    m = Model("M2_ZipZorp", "ground centre between the skates; faces -Z", budget=3000)
    skin = m.piece("Skin", ALIEN_GREEN, material="Smooth")
    gloves = m.piece("Gloves", (250, 250, 255), material="Smooth")
    skates = m.piece("Skates", CORAL_C, material="Smooth")
    wheels = m.piece("Wheels", SUNNY, material="Smooth")
    vest = m.piece("Vest", NAVY, material="StudsSmall")
    bow = m.piece("BowTie", CORAL_C, material="Smooth")
    face = m.piece("Face", INK_M, material="Smooth")
    shine = m.piece("Shine", (255, 255, 255), material="Smooth")
    tray = m.piece("Tray", CHROME, material="Smooth")
    shake = m.piece("Shake", (255, 150, 190), material="Smooth")
    a = toon_biped(
        {"body": skin, "head": skin, "limbs": skin, "hands": gloves, "feet": skates, "wheels": wheels},
        body=(1.2, 1.25, 1.1),
        head=(1.15, 1.05, 1.05),
        head_shape="round",
        leg_h=1.4,
        feet="skates",
        arm_pose={"left": (12.0, 15.0), "right": (8.0, 80.0)},
    )
    hc = a["head"]
    hr = a["head_r"]
    # Three eyes: two big + one smaller in the middle, a little higher.
    eyes(face, shine, hc, hr, yaw=30.0, pitch=8.0, size=0.2, tall=1.25)
    eyes(face, None, hc, (hr[0], hr[1], hr[2]), yaw=0.0, pitch=28.0, size=0.16, tall=1.2)
    smile(face, hc, hr, pitch=-22.0, width=26.0, depth=8.0, thickness=0.05, steps=6)
    # The middle eye's highlight (eyes(shine=None) above skipped it: one dot, up-left).
    from models._critter_kit import surface

    p, n = surface(hc, hr, 0.0, 28.0)
    oriented_ellipsoid(shine, tuple(p + n * 0.04 + Vector((-0.05, 0.08, 0.0))), (0.05, 0.05, 0.025), normal=tuple(n), rings=3, segments=6)
    # Antennae with ball tips.
    top = a["head_top"]
    for sx in (-1, 1):
        tube(skin, [(sx * 0.35, top - 0.2, hc[2]), (sx * 0.55, top + 0.5, hc[2]), (sx * 0.75, top + 1.0, hc[2] - 0.1)], 0.07, sides=5)
        # Ball tips in the (unassigned) wheels piece: rig_split gives them to the Head (R25).
        ellipsoid(wheels, (sx * 0.78, top + 1.12, hc[2] - 0.1), (0.2, 0.2, 0.2), rings=4, segments=8)
    # Waiter vest over the body front + bow tie at the collar.
    bx, by, bz = a["body_c"]
    bw, bh, bd = a["body"]
    front = bz - bd * 0.88
    prism(vest, [(-0.75, by + 0.7, front), (0.75, by + 0.7, front), (0.95, by - 0.7, front), (0.0, by - 0.95, front), (-0.95, by - 0.7, front)], (0, 0, 1), 0.16)
    for i, y in enumerate((by + 0.2, by - 0.25)):
        ellipsoid(wheels, (0.0, y, front - 0.1), (0.08, 0.08, 0.05), rings=3, segments=6)
    for sx in (-1, 1):
        prism(bow, [(0.0, by + 0.95, front - 0.12), (sx * 0.4, by + 1.15, front - 0.12), (sx * 0.4, by + 0.75, front - 0.12)], (0, 0, 1), 0.14)
    # Tray on the right hand (held up and forward) with a milkshake + straw.
    rx, ry, rz = a["hands"]["right"]
    ty = ry + 0.35
    disc(tray, (rx, ty, rz), 0.8, 0.08, segments=12, bevel=0.02)
    revolve(shake, [(0.0, 0.0), (0.2, 0.0), (0.3, 0.8), (0.0, 0.8)], center=(rx, ty + 0.08, rz), segments=8)
    ellipsoid(gloves, (rx, ty + 0.98, rz), (0.28, 0.2, 0.28), rings=4, segments=8)
    # Straw in the (unassigned) gloves piece: nearest bone = ArmR, so it rides the tray (R25).
    cylinder(gloves, (rx + 0.05, ty + 1.0, rz), (rx + 0.25, ty + 1.6, rz + 0.05), 0.04, segments=4)
    rig_split(m, toon_bones(a), assign={"Vest": "Torso", "BowTie": "Torso", "Tray": "ArmR", "Shake": "ArmR"})
    return m


def build_landing_lights():
    """
    A 12-stud row of four runway light posts (pivot = ground centre of the row, runs along X): low
    chrome posts with navy collars and small glowing mint globes (`Bulb*` pieces, one per pair so
    every Neon piece stays a small R19 accent).
    """
    m = Model("M2_LandingLights", "ground centre of the row; runs along X (12 long)", budget=900)
    chrome = m.piece("Posts", CHROME)
    collar = m.piece("Collars", NAVY)
    for k, x in enumerate((-4.5, -1.5, 1.5, 4.5)):
        disc(chrome, (x, 0, 0), 0.45, 0.12, segments=8, bevel=0.03)
        cylinder(chrome, (x, 0.12, 0), (x, 1.5, 0), 0.12, segments=6)
        cylinder(collar, (x, 1.45, 0), (x, 1.7, 0), 0.24, segments=8)
        bulb = m.piece(f"BulbRunway{'AB'[k // 2]}", (150, 255, 210), material="Neon")
        ellipsoid(bulb, (x, 1.98, 0), (0.3, 0.3, 0.3), rings=5, segments=8)
    return m


BUILDERS = {
    "M2_Floor": build_floor,
    "M2_EntryArch": build_arch,
    "M2_DinerHall": build_diner_hall,
    "M2_DinerCounter": build_diner_counter,
    "M2_NeonSign": build_neon_sign,
    "M2_StarRegister": build_star_register,
    "M2_BoothSeats": build_booth_seats,
    "M2_RocketJukebox": build_rocket_jukebox,
    "M2_ShakeMachine": build_shake_machine,
    "M2_CraterTables": build_crater_tables,
    "M2_ZipZorp": build_zip_zorp,
    "M2_LandingLights": build_landing_lights,
}
