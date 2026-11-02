"""
area10.py — Area 10 "Mega Nuclear Facility" (spec §3.10), the finale and the most impressive area:
a giant white reactor dome with a glowing green Core band, twin hyperboloid cooling towers puffing
cartoon steam, a turbine hall with a big spinning turbine on its front, power pylons, a control
tower, a glowing pink Fusion Core and — the finale — a giant Golden Atom Statue crowning the dome.
Every pad purchase is its own model set so each one builds in separately; placement lives in
src/shared/Config/AreaLayouts/Area10.luau (slot-local frame, docs/areas-art.md "Area 10").
Area 10 may use height up to 140 studs (plan "World layout"); the skyline tops out at ~81.

Models (key: pivot / notes)                                             build key
    A10_Floor           SLOT ORIGIN pivot (layout cf = identity); top y = 0.5   base
    A10_EntryArch       ground centre between the posts; 2-line letters         base
    A10_ReactorDome     PRODUCER: ground centre (slot (0, 0.5, 46)); Core =     A10_ReactorDome
                        glowing band + oculus + door strip; crown top y = 28.6
    A10_CoolingTower    left tower (slot (-35, 0.5, 53)), 58 tall; feed pipe    A10_CoolingTower
                        runs toward the dome (+X); Steam = cartoon puffs
    A10_CoolingTower2   right tower (slot (35, 0.5, 53)), 64 tall, mirrored     A10_CoolingTower2
                        pipe (-X), extra glow band
    A10_TurbineHall     ground centre; Turbine rotor on the front (-Z) face     A10_TurbineHall
    A10_PowerLines      middle-pylon foot (slot (34, 0.5, 34.5)); 3 pylons      A10_PowerLines
                        along X + cables + a drop to the turbine hall roof post
    A10_ControlTower    ground centre; glass cab at y 35..39.6; Radar spins     A10_ControlTower
    A10_FusionCore      ground centre; Plasma torus, Orb, Gyro rings            A10_FusionCore
    A10_ChiefEngineer   Manager: hard-hat engineer + blueprint table            A10_ChiefEngineer
    A10_GoldenAtom      FINALE: pivot = dome crown (slot (0, 29.1, 46));        A10_GoldenAtom
                        golden spire, nucleus, three orbit rings + electrons

Animation / FX contract (client, B4/B6) — summary, full table in docs/areas-art.md "Area 10":
    Piece names follow src/shared/Config/WorldFxConfig (B4's WorldFxController animates by name,
    about each piece's OWN bbox centre), so these animate with no extra code:
    A10_ReactorDome.Core            "Core": pulsing light (band + oculus + door strip).
    A10_CoolingTower*.Steam         "Steam": steam particles from the puff cluster above the rim.
    A10_CoolingTower*.CoreBand      "Core": pulsing waist glow band(s).
    A10_TurbineHall.Turbine         "Turbine": spin Z (8 symmetric blades -> bbox centre on the axis).
    A10_TurbineHall.VentGlow        "VentGlow": pulsing stack rings + power-post insulators.
    A10_ControlTower.Radar          alias "Dish": oscillates about Y (symmetric bar).
    A10_FusionCore.RotorGyro / .GlowOrb / .CorePlasma   spin Y / float + light / pulse.
    A10_GoldenAtom.RotorOrbits + .RotorElectrons        spin Y in sync about the nucleus axis.
    A10_GoldenAtom.CoreHalo, A10_EntryArch.CoreRing     "Core": pulsing light.
    *.Beacon, *.Insulators, A10_Floor.Lamps (alias "Bulb": light)   static Neon.

Budgets (docs/world-art.md §4): finale hero landmarks (dome, towers, atom, pylons) <= 6,000 — the
"Hero landmark" class; machines/buildings <= 5,000; manager <= 3,000; base floor/arch <= 6,000.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import (
    CHARCOAL,
    CONCRETE,
    CONCRETE_DARK,
    DARK_STEEL,
    DEEP_BLUE,
    GLASS,
    GLOW_GREEN,
    GLOW_LIGHT,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    LAMP_WARM,
    LIME,
    MINT,
    Model,
    ORANGE,
    SKY_BLUE,
    STEEL,
    TOY_RED,
    WHITE,
    YELLOW,
)
from snkit.kit import block, disc, hazard_band, hazard_floor, hazard_ring, trefoil
from snkit.shapes import bar, box, cylinder, ellipsoid, prism, revolve, ring_tube, rot_x, rot_y, rot_z

from models.area01 import LOT_TOP, SKIN, SLOT_PIVOT, lot_stripes
from models.area04 import Xf, toy_figure
from models.area09 import CONCRETE_LIGHT, GOLD, band, cable, disc_z, text_arch

# ------------------------------------------------------------------------------------------------
# Area-local palette + shared geometry constants (mirrored in AreaLayouts/Area10.luau)
# ------------------------------------------------------------------------------------------------

PATH_GREEN = (74, 176, 104)  # facility walkway paint (ties to the glowing-green nuke cores)
SLATE = (74, 82, 100)  # arch posts, wall body
SHELL = (238, 238, 242)  # cooling tower concrete (near-white toy plastic)
PYLON = (126, 134, 152)  # pylon lattice
GOLD_LIGHT = (255, 226, 120)  # alternate nucleons on the atom
GOLD_DARK = (214, 150, 34)  # atom base collar
PLASMA = (255, 96, 214)  # fusion plasma (Neon) — distinct from the reactor's green
ORB = (255, 244, 196)  # fusion "sun" (Neon)

SLOT_W = 104.0
SLOT_D = 70.0
DOME_R = 15.0  # reactor drum radius
DOME_TOP = 28.6  # crown top (local y); the Golden Atom pivot sits here
TOWER_H = 58.0  # left tower rim height (right tower = TOWER_H + 6)


# ------------------------------------------------------------------------------------------------
# Base: floor + entry arch
# ------------------------------------------------------------------------------------------------


def build_floor():
    """
    Facility ground (slot-origin pivot): two-tone concrete plates, a green hazard-edged walkway from
    the road to the dome plaza, a dark plaza disc with a hazard ring around the reactor (slot
    (0, 46)), yellow pad-zone guide lines, a low slate perimeter wall with yellow caps on the sides
    and back, and two floodlight poles flanking the walkway.
    """
    m = Model("A10_Floor", SLOT_PIVOT, budget=6000)
    slab = m.piece("Slab", CONCRETE)
    slab2 = m.piece("SlabLight", CONCRETE_LIGHT)
    apron = m.piece("Apron", CONCRETE_DARK)
    path = m.piece("Path", PATH_GREEN)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    guide = m.piece("Guide", YELLOW)
    wall = m.piece("Wall", SLATE)
    pole = m.piece("Poles", DARK_STEEL)
    lamps = m.piece("Lamps", LAMP_WARM, material="Neon")
    t = LOT_TOP
    lot_stripes(slab, slab2, -SLOT_W / 2, SLOT_W / 2, 0.0, SLOT_D, stripe=8.0, top=t, along="z")
    # Walkway (ends where the plaza hazard ring begins) with hazard-striped edges.
    walk_end = 25.6
    block(path, (0, t + 0.04, walk_end / 2), (10.0, 0.08, walk_end), bevel=0.03)
    for sx in (-1, 1):
        hazard_floor(yellow, black, (sx * 5.6, t + 0.05, walk_end / 2), (1.2, walk_end), 0.1, stripe=1.0, angle=45.0)
    # Plaza around the reactor + hazard ring.
    disc(apron, (0, t, 46.0), 19.0, 0.07, segments=44, bevel=0.03)
    hazard_ring(yellow, black, (0, 0, 46.0), 19.0, 20.5, t, t + 0.1, count=40)
    for sx in (-1, 1):
        block(guide, (sx * 28.5, t + 0.05, 18.6), (43.0, 0.1, 0.5), bevel=0.03)
    # Low perimeter wall (sides + back) with yellow caps; open toward the road.
    wh = 2.2
    block(wall, (0, t + wh / 2, SLOT_D - 0.6), (SLOT_W, wh, 1.2), bevel=0.15)
    block(yellow, (0, t + wh + 0.15, SLOT_D - 0.6), (SLOT_W + 0.2, 0.3, 1.4), bevel=0.08)
    for sx in (-1, 1):
        x = sx * (SLOT_W / 2 - 0.6)
        block(wall, (x, t + wh / 2, SLOT_D / 2 + 1.4), (1.2, wh, SLOT_D - 2.8), bevel=0.15)
        block(yellow, (x, t + wh + 0.15, SLOT_D / 2 + 1.4), (1.4, 0.3, SLOT_D - 2.6), bevel=0.08)
    # Floodlight poles flanking the walkway at the build-zone edge.
    for sx in (-1, 1):
        x = sx * 8.0
        block(pole, (x, t + 0.3, 21.5), (1.6, 0.6, 1.6), bevel=0.15)
        cylinder(pole, (x, t + 0.6, 21.5), (x, t + 13.0, 21.5), 0.3, segments=8)
        block(pole, (x, t + 13.3, 21.3), (2.6, 0.5, 1.4), bevel=0.1)
        block(lamps, (x, t + 12.95, 21.1), (2.2, 0.3, 1.0), bevel=0.06)
    return m


def build_entry_arch():
    """
    "MEGA NUCLEAR / FACILITY" arch: double-sided area09.text_arch (letters read correctly from the
    road AND from inside the facility, owner R17) in slate / hazard yellow / charcoal with green
    letters, plus a big glowing trefoil emblem (yellow disc, black trefoils on both faces, green Neon
    ring) on top of the board.
    """
    m = text_arch(
        "A10_EntryArch",
        ["MEGA NUCLEAR", "FACILITY"],
        inner=22.0,
        post_color=SLATE,
        trim_color=HAZARD_YELLOW,
        panel_color=CHARCOAL,
        letter_color=GLOW_GREEN,
        finial_colors=(LIME, MINT),
    )
    info = m.arch_info
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    glow = m.piece("CoreRing", GLOW_GREEN, material="Neon")  # WorldFx "Core": pulsing light, no motion
    posts = m.piece("Posts", SLATE)
    top = info["top_y"]
    cy = top + 3.6
    block(posts, (0, top + 0.6, 0), (3.0, 1.2, 1.6), bevel=0.2)
    disc_z(yellow, (0, cy, 0), 2.9, 0.8, segments=20)
    trefoil(black, (0, cy, -0.48), 2.3, 0.14, normal=(0, 0, -1))
    trefoil(black, (0, cy, 0.48), 2.3, 0.14, normal=(0, 0, 1))
    revolve(glow, [(2.95, -0.3), (3.45, -0.3), (3.45, 0.3), (2.95, 0.3)], center=(0, cy, 0), segments=20, closed=True, rot=rot_x(90))
    return m


# ------------------------------------------------------------------------------------------------
# Producer: reactor dome
# ------------------------------------------------------------------------------------------------


def build_reactor_dome():
    """
    The Mega Reactor: light-concrete drum (r = 15, 9 tall) with a glowing green Core band, a deep
    blue band and a hazard foot ring; a white dome with 12 steel ribs, a big tilted trefoil badge on
    the front, a steel crown with a glowing oculus (Core) on top, and a hazard-trimmed door portal.
    """
    m = Model(
        "A10_ReactorDome",
        "ground centre (layout: slot (0, 0.5, 46)); door faces -Z; crown top y = 28.6 = Golden Atom pivot; "
        "Core = Neon band + oculus + door strip",
        budget=6000,
    )
    drum = m.piece("Drum", (214, 216, 226))
    dome = m.piece("Dome", WHITE)
    ribs = m.piece("Ribs", STEEL)
    blue = m.piece("Band", DEEP_BLUE)
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    portal = m.piece("Portal", DARK_STEEL)
    r = DOME_R
    revolve(drum, [(0.0, 0.0), (r, 0.0), (r, 8.6), (r - 0.3, 9.0), (0.0, 9.0)], segments=40)
    hazard_ring(yellow, black, (0, 0, 0), r, r + 1.4, 0.0, 0.14, count=40)
    revolve(core, [(r - 0.1, 4.0), (r + 0.22, 4.0), (r + 0.22, 5.4), (r - 0.1, 5.4)], segments=40, closed=True)
    band(blue, 0, 0, r, 7.0, 7.8, out=0.18, segments=40)
    profile = [(14.6, 8.8), (14.3, 12.0), (13.3, 16.0), (11.6, 20.0), (9.1, 23.5), (6.0, 26.2), (3.6, 27.6)]
    revolve(dome, [(0.0, 8.8)] + profile + [(0.0, 27.9)], segments=40)
    # Twelve meridian ribs following the dome profile (offset 0.15 outward).
    for k in range(12):
        a = k * math.pi / 6 + math.pi / 12
        dx, dz = math.cos(a), math.sin(a)
        pts = [(dx * (rr + 0.15), y, dz * (rr + 0.15)) for rr, y in profile]
        for p, q in zip(pts, pts[1:]):
            bar(ribs, p, q, 0.5)
    # Crown ring + glowing oculus (Core) on top.
    revolve(portal, [(2.6, 27.3), (4.0, 27.3), (4.0, 28.0), (3.6, DOME_TOP), (2.6, DOME_TOP)], segments=24, closed=True)
    disc(core, (0, 27.4, 0), 2.7, 1.0, segments=24, bevel=0.2)
    # Big trefoil badge on the dome front, tilted to the surface (normal ~ (0, 0.24, -0.97)).
    n = Vector((0.0, 0.242, -0.970)).normalized()
    up = Vector((0.0, 0.970, 0.242))
    c = Vector((0.0, 15.5, -13.43)) + n * 0.2
    revolve(yellow, [(0.0, -0.6), (3.4, -0.6), (3.4, 0.6), (0.0, 0.6)], center=(c.x, c.y, c.z), segments=24, rot=rot_x(-76))
    t = c + n * 0.66
    trefoil(black, (t.x, t.y, t.z), 2.6, 0.14, normal=tuple(n), up=tuple(up))
    # Door portal at the front: steel frame, hazard kick band, blue door, glowing strip above.
    block(portal, (0, 3.7, -r - 0.2), (8.0, 7.4, 2.6), bevel=0.25)
    hazard_band(yellow, black, (0, 0.65, -r - 1.56), (7.6, 0.9, 0.12), stripe=0.6)
    block(blue, (0, 3.4, -r - 1.55), (4.6, 5.0, 0.2), bevel=0.06)
    block(core, (0, 6.5, -r - 1.55), (5.2, 0.5, 0.2), bevel=0.06)
    return m


# ------------------------------------------------------------------------------------------------
# Cooling towers
# ------------------------------------------------------------------------------------------------


def _shell_radius(profile, y):
    """Linear interpolation of a [(radius, y)] profile (ascending y) at height y."""
    for (r0, y0), (r1, y1) in zip(profile, profile[1:]):
        if y0 <= y <= y1:
            t = (y - y0) / max(y1 - y0, 1e-6)
            return r0 + (r1 - r0) * t
    return profile[-1][0]


def _cooling_tower(key, height, pipe_dir, reach, mk2):
    """
    Hyperboloid cooling tower: open-leg base ring, hollow near-white shell (inner wall + dark
    floor so it reads hollow from above), red stripes near the top, a steel rim catwalk with
    railing posts, a glowing green waist band (two on mk2), a cartoon Steam puff cluster above
    the rim, and a big steel feed pipe running toward the reactor along `pipe_dir` (unit XZ) out to
    `reach` studs from the tower axis (0.6 inside the reactor drum).
    """
    m = Model(
        key,
        f"ground centre; rim top y = {height:g}; Steam puffs above the rim (particle anchor); "
        "feed pipe runs toward the reactor dome",
        budget=6000,
    )
    shell = m.piece("Shell", SHELL)
    legs = m.piece("Legs", CONCRETE_DARK)
    inside = m.piece("Inside", CHARCOAL, material="Smooth")
    stripes = m.piece("Stripes", TOY_RED)
    rim = m.piece("Rim", DARK_STEEL)
    glow = m.piece("CoreBand", GLOW_GREEN, material="Neon")  # WorldFx "Core": pulsing light, no motion
    steam = m.piece("Steam", WHITE, material="Smooth", transparency=0.1)
    pipes = m.piece("Pipes", STEEL)
    blue = m.piece("Band", DEEP_BLUE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    h = height
    base_y = 4.2
    outer = [(15.0, base_y), (13.4, 0.2 * h), (11.2, 0.45 * h), (10.0, 0.68 * h), (9.9, 0.78 * h), (10.2, 0.88 * h), (10.9, h)]
    inner = [(10.2, h), (9.5, 0.88 * h), (9.2, 0.78 * h), (9.3, 0.68 * h), (10.5, 0.45 * h), (12.7, 0.2 * h), (14.2, 6.0)]
    revolve(shell, [(0.0, base_y)] + outer + inner + [(0.0, 6.0)], segments=36)
    disc(inside, (0, 6.02, 0), 13.9, 0.1, segments=24, bevel=0.03)
    # Leaning legs under the shell (pairs crossing like real tower supports).
    for k in range(20):
        a = 2 * math.pi * k / 20
        lean = math.radians(7.0) * (1 if k % 2 == 0 else -1)
        x0, z0 = 14.8 * math.cos(a), 14.8 * math.sin(a)
        x1, z1 = 14.6 * math.cos(a + lean), 14.6 * math.sin(a + lean)
        bar(legs, (x0, 0.0, z0), (x1, base_y + 0.4, z1), 0.7)
    hazard_ring(yellow, black, (0, 0, 0), 15.3, 16.7, 0.0, 0.12, count=36)
    # Blue band just above the legs; red stripes near the top; green glow band(s) at the waist.
    band(blue, 0, 0, _shell_radius(outer, base_y + 1.6), base_y + 1.0, base_y + 2.2, out=0.2, segments=36)
    for y0, y1 in ((0.8 * h, 0.85 * h), (0.91 * h, 0.96 * h)):
        rr = max(_shell_radius(outer, y0), _shell_radius(outer, y1))
        band(stripes, 0, 0, rr, y0, y1, out=0.18, segments=36)
    for gy in ((0.62 * h,) if not mk2 else (0.58 * h, 0.66 * h)):
        band(glow, 0, 0, _shell_radius(outer, gy), gy - 0.45, gy + 0.45, out=0.16, segments=36)
    # Rim catwalk ring + railing posts.
    revolve(rim, [(10.0, h - 0.05), (11.6, h - 0.05), (11.6, h + 0.45), (10.0, h + 0.45)], segments=36, closed=True)
    for k in range(12):
        a = 2 * math.pi * k / 12
        x, z = 11.35 * math.cos(a), 11.35 * math.sin(a)
        bar(rim, (x, h + 0.45, z), (x, h + 1.7, z), 0.18)
    ring_tube(rim, (0, h + 1.65, 0), 11.35, 0.2, 0.2, segments=36)
    # Cartoon steam: chunky puffs rising out of the rim (client adds rising particle puffs here).
    for (sx, sy, sz, rx, ry) in ((0.0, 3.0, 0.0, 8.6, 3.8), (3.0, 6.8, -1.2, 6.2, 3.4), (-2.8, 9.2, 1.8, 5.0, 3.0), (0.9, 11.8, 0.2, 3.6, 2.4)):
        ellipsoid(steam, (sx, h + sy, sz), (rx, ry, rx), rings=7, segments=14)
    # Feed pipe toward the reactor: from inside the leg ring out into the drum along pipe_dir.
    dx, dz = pipe_dir
    p0 = (dx * 14.0, 3.0, dz * 14.0)
    p1 = (dx * reach, 3.0, dz * reach)
    cylinder(pipes, p0, p1, 1.1, segments=12)
    for d in (15.6, reach - 1.4):
        revolve(pipes, [(1.05, -0.3), (1.45, -0.3), (1.45, 0.3), (1.05, 0.3)], center=(dx * d, 3.0, dz * d), segments=12, closed=True, rot=rot_y(-math.degrees(math.atan2(dz, dx))) @ rot_z(90))
    mid = (14.0 + reach) / 2
    block(legs, (dx * mid, 1.0, dz * mid), (1.6, 2.0, 1.6), bevel=0.2, rot=rot_y(-math.degrees(math.atan2(dz, dx))))
    return m


# Tower placement relative to the dome (layout: towers at slot (+-35, 0.5, 53), dome at (0, 0.5, 46)).
TOWER_TO_DOME = Vector((35.0, -7.0))
PIPE_REACH = TOWER_TO_DOME.length - DOME_R + 0.6  # pipe end 0.6 inside the reactor drum


def build_cooling_tower():
    """Left tower (slot (-35, 0.5, 53)); its pipe runs toward the dome centre (+35, -7) -> +X."""
    d = TOWER_TO_DOME.normalized()
    return _cooling_tower("A10_CoolingTower", TOWER_H, (d.x, d.y), PIPE_REACH, mk2=False)


def build_cooling_tower_2():
    """Right tower (slot (35, 0.5, 53)), 6 studs taller with two glow bands; pipe toward -X."""
    d = Vector((-TOWER_TO_DOME.x, TOWER_TO_DOME.y)).normalized()
    return _cooling_tower("A10_CoolingTower2", TOWER_H + 6.0, (d.x, d.y), PIPE_REACH, mk2=True)


# ------------------------------------------------------------------------------------------------
# Turbine hall, power lines, control tower
# ------------------------------------------------------------------------------------------------

TURBINE_C = (-5.5, 5.6, -6.75)  # rotor bbox centre (local); axis = Z


def build_turbine_hall():
    """
    Turbine hall: sky-blue hall (24 x 12 x 9) under a deep-blue barrel roof, a big yellow 8-blade
    Turbine in a steel housing on the front (spins about its bbox centre, axis Z), a roll-up door,
    a window strip, a lightning-bolt sign, two roof stacks with green glow rings and a roof power
    post at the back (the A10_PowerLines drop cable lands on it).
    """
    m = Model(
        "A10_TurbineHall",
        "ground centre; front -Z; Turbine spins about its own bbox centre (local (-5.5, 5.6, -6.75)), axis Z; "
        "power post top at local (4, 14.5, 4)",
        budget=5000,
    )
    base = m.piece("Base", CONCRETE)
    walls = m.piece("Walls", SKY_BLUE)
    roof = m.piece("Roof", DEEP_BLUE)
    trim = m.piece("Trim", WHITE)
    housing = m.piece("Housing", DARK_STEEL)
    back = m.piece("Backing", CHARCOAL, material="Smooth")  # not "Fan*": that WorldFx row would spin it
    turbine = m.piece("Turbine", YELLOW)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.35)
    stacks = m.piece("Stacks", STEEL)
    glow = m.piece("VentGlow", GLOW_GREEN, material="Neon")  # WorldFx "VentGlow": pulsing light, no motion
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    W, D, H = 24.0, 12.0, 9.0
    zf = -D / 2
    block(base, (0, 0.25, 0), (W + 0.8, 0.5, D + 0.8), bevel=0.15)
    block(walls, (0, 0.5 + H / 2, 0), (W, H, D), bevel=0.2)
    # Corner pilasters + eave trim.
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(trim, (sx * (W / 2 - 0.3), 0.5 + H / 2, sz * (D / 2 - 0.3)), (1.0, H + 0.2, 1.0), bevel=0.15)
    block(trim, (0, 0.5 + H + 0.2, 0), (W + 0.6, 0.5, D + 0.6), bevel=0.12)
    # Barrel roof: half-ellipse (rz = 6.4, ry = 3.6) extruded along X.
    ry, rz = 3.6, 6.4
    y0 = 0.5 + H + 0.4
    # prism() extrudes SYMMETRICALLY about the outline plane, so the outline sits at x = 0 (it was at
    # -(W/2 + 0.4), which shifted the whole roof half a hall toward -X: half the hall had no roof
    # and the roof overhung 12.8 studs into the floodlight pole; check_area_overlaps.py, A1-art).
    outline = [(0.0, y0 + ry * math.sin(math.pi * k / 12), rz * math.cos(math.pi * k / 12)) for k in range(13)]
    prism(roof, outline, (1, 0, 0), W + 0.8)
    # Turbine: housing ring (axis Z), dark backing, yellow 8-blade rotor (symmetric -> bbox on axis).
    cx, cy, cz = TURBINE_C
    revolve(housing, [(4.3, -0.75), (5.3, -0.75), (5.3, 0.75), (4.3, 0.75)], center=(cx, cy, zf - 0.55), segments=28, closed=True, rot=rot_x(90))
    disc_z(back, (cx, cy, zf - 0.08), 4.35, 0.16, segments=24)
    ellipsoid(turbine, (cx, cy, cz), (1.25, 1.25, 0.7), rings=6, segments=12)
    for k in range(8):
        phi = k * 45.0
        r = rot_z(phi) @ rot_y(28.0)
        off = rot_z(phi) @ Vector((0.0, 2.55, 0.0))
        block(turbine, (cx + off.x, cy + off.y, cz + off.z), (1.0, 3.3, 0.24), bevel=0.04, rot=r)
    # Roll-up door with hazard kick plate, window strip above, lightning-bolt sign.
    dx = 6.0
    for i in range(6):
        block(trim, (dx, 0.5 + 6.0 - i * 0.98 - 0.49, zf - 0.12), (6.0, 0.94, 0.3), bevel=0.08)
    hazard_band(yellow, black, (dx, 0.85, zf - 0.32), (6.0, 0.7, 0.12), stripe=0.6)
    for sx in (-1, 1):
        block(housing, (dx + sx * 3.25, 0.5 + 3.2, zf - 0.2), (0.5, 6.4, 0.5), bevel=0.08)
    block(housing, (dx, 0.5 + 6.5, zf - 0.2), (7.0, 0.5, 0.5), bevel=0.08)
    for x in (2.5, 6.0, 9.5):
        box(glass, (x, 0.5 + 7.75, zf - 0.05), (2.6, 1.3, 0.2))
        block(trim, (x, 0.5 + 7.0, zf - 0.15), (2.9, 0.22, 0.4), bevel=0.04)
    block(yellow, (10.9, 0.5 + 3.4, zf - 0.15), (2.2, 3.0, 0.2), bevel=0.08)
    bolt = [(10.6, 5.4, zf - 0.3), (11.3, 5.4, zf - 0.3), (10.95, 4.1, zf - 0.3), (11.5, 4.1, zf - 0.3), (10.4, 2.4, zf - 0.3), (10.75, 3.7, zf - 0.3), (10.25, 3.7, zf - 0.3)]
    prism(black, list(reversed(bolt)), (0, 0, 1), 0.1)
    # Roof stacks with glowing rings + the power post for the pylon drop cable.
    roof_y = y0 + ry * 0.55
    for sx in (-1, 1):
        cylinder(stacks, (sx * 7.0, roof_y - 1.0, 2.0), (sx * 7.0, 16.6, 2.0), 0.8, segments=12)
        disc(stacks, (sx * 7.0, 16.6, 2.0), 1.05, 0.35, segments=12, bevel=0.1)
        band(glow, sx * 7.0, 2.0, 0.8, 15.4, 16.1, out=0.12, segments=12)
    cylinder(stacks, (4.0, roof_y - 1.0, 4.0), (4.0, 14.0, 4.0), 0.3, segments=8)
    # Insulator discs (bottoms 13.35 / 13.8 / 14.25): the post top (14.0) ends INSIDE the middle disc,
    # never flush with a disc face (R18); the top disc (top 14.47) takes the pylon drop cable.
    for y in (13.35, 13.8, 14.25):
        disc(glow, (4.0, y, 4.0), 0.55, 0.22, segments=10, bevel=0.06)
    return m


def build_power_lines():
    """
    Three tapered lattice pylons along local X (-13, 0, 13), yellow crossarms along Z, green glowing
    insulators, red beacons, sagging cables between them and a drop cable from the middle pylon's
    front lower arm down to the turbine hall's roof power post.
    """
    m = Model(
        "A10_PowerLines",
        "middle pylon foot (layout: slot (34, 0.5, 34.5)); pylons at local x = -13, 0, 13; cables along X; "
        "drop cable lands at local (0, 14.5, -5.5) = turbine hall power post (hall at slot (30, 0.5, 25))",
        budget=6000,
    )
    steel = m.piece("Lattice", PYLON)
    arms = m.piece("Arms", HAZARD_YELLOW)
    glow = m.piece("Insulators", GLOW_GREEN, material="Neon")  # static glow (no WorldFx row)
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    wire = m.piece("Cables", CHARCOAL, material="Smooth")
    feet = m.piece("Footings", CONCRETE)
    levels = [(0.0, 2.4), (6.0, 2.0), (12.0, 1.65), (17.0, 1.35), (22.0, 1.05), (27.0, 0.8), (30.0, 0.6)]
    xs = (-13.0, 0.0, 13.0)
    arm_specs = ((27.0, 3.8), (21.5, 4.8))  # (height, half-length along Z)
    for px in xs:
        for sx in (-1, 1):
            for sz in (-1, 1):
                block(feet, (px + sx * 2.4, 0.4, sz * 2.4), (1.4, 0.8, 1.4), bevel=0.15)
        corners = lambda y, hw: [(px - hw, y, -hw), (px + hw, y, -hw), (px + hw, y, hw), (px - hw, y, hw)]  # noqa: E731
        for (y0, w0), (y1, w1) in zip(levels, levels[1:]):
            c0, c1 = corners(y0, w0), corners(y1, w1)
            for k in range(4):
                bar(steel, c0[k], c1[k], 0.42)
                k2 = (k + 1) % 4
                if y1 - y0 > 3.5:
                    bar(steel, c0[k], c1[k2], 0.26)
                    bar(steel, c0[k2], c1[k], 0.26)
            for k in range(4):
                bar(steel, c1[k], c1[(k + 1) % 4], 0.3)
        # Spike + beacon.
        cylinder(steel, (px, 30.0, 0), (px, 32.6, 0), 0.22, segments=6)
        ellipsoid(beacon, (px, 32.9, 0), (0.42, 0.42, 0.42), rings=4, segments=8)
        for y, hl in arm_specs:
            bar(arms, (px, y, -hl), (px, y, hl), 0.55)
            for sz in (-1, 1):
                bar(arms, (px, y - 0.2, sz * hl * 0.55), (px, y - 2.2, sz * 1.05), 0.3)
                # Insulator stack hanging from the arm tip.
                iz = sz * (hl - 0.25)
                cylinder(glow, (px, y - 0.3, iz), (px, y - 1.5, iz), 0.22, segments=6)
                for iy in (y - 0.7, y - 1.2):
                    ellipsoid(glow, (px, iy, iz), (0.42, 0.12, 0.42), rings=3, segments=6)
    # Cables between pylons, hanging from the insulator bottoms.
    for y, hl in arm_specs:
        for sz in (-1, 1):
            z = sz * (hl - 0.25)
            for a, b in zip(xs, xs[1:]):
                cable(wire, (a, y - 1.5, z), (b, y - 1.5, z), 1.6, thick=0.2, steps=8)
    # Drop cable: middle pylon front lower arm tip -> turbine hall roof post (local (0, 14.5, -5.5)).
    tip = (0.0, 21.5 - 1.5, -(4.8 - 0.25))
    cable(wire, tip, (0.0, 14.5, -5.5), 0.4, thick=0.2, steps=6)
    return m


def build_control_tower():
    """
    Control tower (~48 tall): concrete plinth, white shaft with sky-blue window strips, a glass
    control cab with glowing consoles inside, a balcony rail, a roof Radar bar (spins about its
    bbox centre, axis Y), an antenna mast and a red beacon.
    """
    m = Model(
        "A10_ControlTower",
        "ground centre; door faces -Z; cab y 35..39.6; Radar spins about its own bbox centre (axis Y); Beacon blinks",
        budget=5000,
    )
    plinth = m.piece("Plinth", CONCRETE)
    shaft = m.piece("Shaft", WHITE)
    windows = m.piece("Windows", SKY_BLUE, material="Smooth")
    trim = m.piece("Trim", DEEP_BLUE)
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.4)
    screens = m.piece("Screens", LIME, material="Neon")
    mast = m.piece("Mast", STEEL, material="StudsSmall")
    radar = m.piece("Radar", WHITE, material="StudsSmall")
    beacon = m.piece("Beacon", TOY_RED, material="Neon")
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    block(plinth, (0, 0.5, 0), (10.0, 1.0, 10.0), bevel=0.2)
    for zs in (-1, 1):
        hazard_band(yellow, black, (0, 0.5, zs * 5.04), (9.6, 0.7, 0.12), stripe=0.6)
    sw = 6.4
    block(shaft, (0, 1.0 + 16.5, 0), (sw, 33.0, sw), bevel=0.25)
    for k, (nx, nz) in enumerate(((0, -1), (0, 1), (-1, 0), (1, 0))):
        if nz != 0:
            block(windows, (0, 19.5, nz * (sw / 2 + 0.05)), (1.3, 24.0, 0.2), bevel=0.05)
        else:
            block(windows, (nx * (sw / 2 + 0.05), 19.5, 0), (0.2, 24.0, 1.3), bevel=0.05)
    block(trim, (0, 3.4, -sw / 2 - 0.1), (2.6, 4.6, 0.3), bevel=0.08)
    for y in (8.0, 16.0, 24.0):
        # Bands stand 0.15 proud of the window strips (faces at sw/2 + 0.15), never flush (R18).
        block(trim, (0, y, 0), (sw + 0.6, 0.5, sw + 0.6), bevel=0.1)
    # Cab: floor, glass walls, corner posts, roof + fascia, consoles inside.
    block(trim, (0, 34.5, 0), (11.4, 1.0, 11.4), bevel=0.2)
    box(glass, (0, 37.35, 0), (10.4, 4.7, 10.4))  # top ends inside the roof slab, not flush with the posts (R18)
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(trim, (sx * 5.1, 37.3, sz * 5.1), (0.6, 4.6, 0.6), bevel=0.08)
    block(shaft, (0, 39.95, 0), (12.0, 0.7, 12.0), bevel=0.2)
    block(trim, (0, 40.5, 0), (9.0, 0.5, 9.0), bevel=0.12)
    for sx in (-1, 1):
        block(screens, (sx * 3.6, 36.4, 0), (0.6, 0.8, 6.0), bevel=0.06)
        block(screens, (0, 36.4, sx * 3.6), (6.0, 0.8, 0.6), bevel=0.06)
    # Balcony rail on the cab floor edge.
    for k in range(16):
        a = k / 16.0
        side = int(a * 4)
        u = (a * 4 - side) * 11.0 - 5.5
        x, z = ((u, -5.6), (5.6, u), (-u, 5.6), (-5.6, -u))[side]
        bar(mast, (x, 35.0, z), (x, 36.0, z), 0.14)
    ring = [(-5.6, 36.0, -5.6), (5.6, 36.0, -5.6), (5.6, 36.0, 5.6), (-5.6, 36.0, 5.6)]
    for p, q in zip(ring, ring[1:] + ring[:1]):
        bar(mast, p, q, 0.16)
    # Roof: radar bar on a post, antenna mast, beacon.
    cylinder(mast, (2.4, 40.75, 2.4), (2.4, 42.4, 2.4), 0.25, segments=8)
    block(radar, (2.4, 42.7, 2.4), (4.0, 0.6, 0.7), bevel=0.12)
    block(radar, (2.4, 43.05, 2.4), (0.7, 0.5, 0.7), bevel=0.1)
    cylinder(mast, (-2.2, 40.75, -1.6), (-2.2, 47.2, -1.6), 0.22, segments=8)
    for y in (43.0, 45.0):
        bar(mast, (-3.2, y, -1.6), (-1.2, y, -1.6), 0.14)
    ellipsoid(beacon, (-2.2, 47.55, -1.6), (0.45, 0.5, 0.45), rings=5, segments=8)
    return m


# ------------------------------------------------------------------------------------------------
# Fusion core, chief engineer, golden atom
# ------------------------------------------------------------------------------------------------


def build_fusion_core():
    """
    Fusion Core: octagonal steel pedestal with a hazard ring, a glowing pink Plasma torus wrapped
    by eight orange magnet coils on four struts, a warm glowing Orb floating above it inside two
    crossed golden Gyro rings (spin about the bbox centre, axis Y), and four white containment
    pillars with pink tips joined by a top ring.
    """
    m = Model(
        "A10_FusionCore",
        "ground centre; CorePlasma torus at y = 4.6; GlowOrb + RotorGyro centre (0, 8.2, 0); RotorGyro spins about its bbox centre (axis Y)",
        budget=5000,
    )
    ped = m.piece("Pedestal", DARK_STEEL)
    plasma = m.piece("CorePlasma", PLASMA, material="Neon")  # WorldFx "Core": pulsing light
    coils = m.piece("Coils", ORANGE)
    orb = m.piece("GlowOrb", ORB, material="Neon")  # WorldFx "Glow": floats (bob) + light
    gyro = m.piece("RotorGyro", GOLD)  # WorldFx "Rotor": spins about its bbox centre, axis Y
    pillars = m.piece("Pillars", WHITE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    revolve(ped, [(0.0, 0.0), (5.6, 0.0), (5.6, 1.3), (5.1, 1.8), (0.0, 1.8)], segments=8)
    hazard_ring(yellow, black, (0, 0, 0), 4.0, 5.0, 1.8, 1.92, count=16)
    ty, tr, tube = 4.6, 3.8, 0.85
    tube_profile = [(tr + tube * math.cos(2 * math.pi * k / 10), tube * math.sin(2 * math.pi * k / 10)) for k in range(10)]
    revolve(plasma, tube_profile, center=(0, ty, 0), segments=28, closed=True)
    for k in range(8):
        phi = 2 * math.pi * k / 8
        cx, cz = tr * math.cos(phi), tr * math.sin(phi)
        rot = rot_y(-math.degrees(phi)) @ rot_x(90)
        revolve(coils, [(1.0, -0.42), (1.55, -0.42), (1.55, 0.42), (1.0, 0.42)], center=(cx, ty, cz), segments=12, closed=True, rot=rot)
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        bar(ped, (math.cos(a) * 3.0, 1.8, math.sin(a) * 3.0), (math.cos(a) * tr, ty - 0.6, math.sin(a) * tr), 0.6)
    oy = 8.2
    ellipsoid(orb, (0, oy, 0), (1.7, 1.7, 1.7), rings=8, segments=14)
    cylinder(ped, (0, 1.8, 0), (0, ty - 0.2, 0), 0.5, segments=8)
    for rot in (rot_x(90), rot_z(90) @ rot_x(90)):
        revolve(gyro, [(2.45, -0.22), (2.85, -0.22), (2.85, 0.22), (2.45, 0.22)], center=(0, oy, 0), segments=24, closed=True, rot=rot)
    # Containment pillars with glowing tips + a top ring.
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        x, z = 5.0 * math.cos(a), 5.0 * math.sin(a)
        cylinder(pillars, (x, 1.8, z), (x, 10.6, z), 0.42, segments=10)
        ellipsoid(plasma, (x, 10.9, z), (0.5, 0.5, 0.5), rings=5, segments=8)
    ring_tube(pillars, (0, 10.2, 0), 5.0, 0.4, 0.4, segments=24)
    return m


def build_chief_engineer():
    """
    Chief Engineer (Manager): area04 toy figure in an orange hi-vis vest and yellow hard hat,
    holding a clipboard, next to a drafting table with a glowing blueprint and a red toolbox.

    Animated NPC (owner R30): the figure is split into rig pieces (Torso*/Head*/ArmL*/ArmR*/LegL*/
    LegR*, see models/_npc_rig.py) so the client ManagerController can walk him around the mat,
    swing his limbs, wave (it raises the relaxed left arm) and tap at the drafting table. Rest pose =
    left arm down. Mat, hazard band, table, blueprint, plan lines and toolbox stay static props (the
    toolbox handle uses the table steel so the model stays under 24 pieces).
    """
    from models._npc_rig import a4_bones, rig_split

    m = Model("A10_ChiefEngineer", "ground centre of the mat; engineer faces -Z; table at local +X", budget=3000)
    mat = m.piece("Mat", CONCRETE_DARK)
    skin = m.piece("Skin", SKIN)
    shirt = m.piece("Shirt", ORANGE)
    pants = m.piece("Pants", DEEP_BLUE)
    dark = m.piece("Dark", CHARCOAL)
    hat = m.piece("Hat", YELLOW)
    accent = m.piece("Stripes", (255, 244, 150), material="StudsSmall")
    table = m.piece("Table", DARK_STEEL)
    print_ = m.piece("Blueprint", SKY_BLUE, material="Smooth")
    lines = m.piece("PrintLines", WHITE, material="Smooth")
    box_ = m.piece("Toolbox", TOY_RED)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    block(mat, (0.6, 0.1, 0), (7.6, 0.2, 4.4), bevel=0.06)
    hazard_band(yellow, black, (0.6, 0.12, -2.22), (7.2, 0.18, 0.08), stripe=0.5)
    xf = Xf((-1.0, 0.2, 0.2))
    toy_figure(
        {"skin": skin, "shirt": shirt, "pants": pants, "dark": dark, "hat": hat, "accent": accent, "paper": lines},
        xf,
        hat="hardhat",
        right_arm="clipboard",
        left_arm="down",
        vest=True,
    )
    # Drafting table: four legs, tilted blueprint board with white plan lines.
    tx, tz = 2.9, 0.4
    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(table, (tx + sx * 1.1, 0.2, tz + sz * 0.8), (tx + sx * 1.1, 3.0, tz + sz * 0.8), 0.22)
    tilt = rot_x(-25)
    block(table, (tx, 3.15, tz), (2.8, 0.2, 2.2), bevel=0.05, rot=tilt)
    block(print_, (tx, 3.29, tz - 0.06), (2.5, 0.06, 1.9), bevel=0.02, rot=tilt)
    for i, (w, x) in enumerate(((1.6, -0.2), (0.9, 0.4), (1.2, 0.1))):
        off = tilt @ Vector((x, 0.06, -0.6 + i * 0.55))
        block(lines, (tx + off.x, 3.3 + off.y, tz + off.z), (w, 0.04, 0.12), bevel=0.01, rot=tilt)
    block(box_, (tx + 0.4, 0.65, tz - 1.5), (1.6, 0.9, 0.9), bevel=0.12)
    bar(table, (tx - 0.1, 1.3, tz - 1.5), (tx + 0.9, 1.3, tz - 1.5), 0.14)
    # Body-part pieces for the client NPC rig (the clipboard rides the right hand). The torso bone's
    # far end is pulled down to the shoulders (local y 4.2) for classification only, so the mouth
    # bars (local y ~4.9, on the face) score nearer the head; the joint (hip) is unchanged. The plan
    # lines on the table share the clipboard paper's piece: they are > reach from every bone, so
    # they keep the name "PrintLines" and stay static.
    bones = a4_bones(xf, left_arm="down", right_arm="clipboard")
    bones["Torso"] = (bones["Torso"][0], xf.p(0.0, 4.2, 0.0))
    rig_split(
        m,
        bones,
        static=("Mat", "Table", "Blueprint", "Toolbox", "HazardYellow", "HazardBlack"),
        frame=((-1.0, 0.2, 0.2), 0.0),
    )
    return m


def build_golden_atom():
    """
    FINALE — the Golden Atom Statue crowning the reactor dome: gold base collar on the dome's crown,
    a tapered golden spire with rings, a nucleus of gold / light-gold spheres, three tilted golden
    orbit rings (Orbits) carrying glowing green Electrons. Orbits + Electrons spin together about
    the vertical axis through the pivot.
    """
    m = Model(
        "A10_GoldenAtom",
        "pivot = reactor dome crown top (layout: slot (0, 29.1, 46)); nucleus centre y = 23; "
        "RotorOrbits + RotorElectrons spin together about the nucleus axis (bbox centres on it)",
        budget=6000,
    )
    collar = m.piece("Collar", GOLD_DARK)
    spire = m.piece("Spire", GOLD)
    light = m.piece("Nucleus", GOLD_LIGHT)
    orbits = m.piece("RotorOrbits", GOLD)  # WorldFx "Rotor": spin Y about the nucleus axis
    electrons = m.piece("RotorElectrons", GLOW_GREEN, material="Neon")  # spins in sync with the orbits
    halo = m.piece("CoreHalo", GLOW_LIGHT, material="Neon")  # WorldFx "Core": pulsing golden-green light
    revolve(collar, [(0.0, 0.0), (4.0, 0.0), (4.0, 0.7), (3.3, 1.3), (0.0, 1.3)], segments=24)
    revolve(spire, [(0.0, 1.2), (1.8, 1.2), (1.25, 6.0), (0.85, 10.6), (0.0, 10.6)], segments=16)
    for y, rr in ((2.6, 1.85), (6.6, 1.4), (9.6, 1.1)):
        band(collar, 0, 0, rr - 0.12, y - 0.3, y + 0.3, out=0.2, segments=16)
    ny = 23.0
    # Nucleus: centre ball + 6 axis balls + 8 diagonal balls, alternating gold shades.
    ellipsoid(spire, (0, ny, 0), (3.3, 3.3, 3.3), rings=8, segments=12)
    for i, (x, y, z) in enumerate(((2.9, 0, 0), (-2.9, 0, 0), (0, 2.9, 0), (0, -2.9, 0), (0, 0, 2.9), (0, 0, -2.9))):
        ellipsoid(light if i % 2 == 0 else spire, (x, ny + y, z), (2.4, 2.4, 2.4), rings=6, segments=10)
    for i in range(8):
        sx, sy, sz = (1 if i & 1 else -1), (1 if i & 2 else -1), (1 if i & 4 else -1)
        ellipsoid(spire if i % 2 == 0 else light, (sx * 2.2, ny + sy * 2.2, sz * 2.2), (2.0, 2.0, 2.0), rings=6, segments=10)
    # Soft glowing halo core peeking between the nucleons.
    ellipsoid(halo, (0, ny, 0), (4.0, 4.0, 4.0), rings=6, segments=10)
    # Three orbit rings tilted 65 deg, spread 60 deg apart. Two electrons per ring at opposite points:
    # rings and electron pairs are point-symmetric about the nucleus, so BOTH pieces' bbox centres sit
    # on the nucleus axis and WorldFx spins them in sync about it (no wobble off the orbits).
    for k in range(3):
        rot = rot_y(60.0 * k) @ rot_z(65.0)
        revolve(orbits, [(12.05, -0.45), (12.95, -0.45), (12.95, 0.45), (12.05, 0.45)], center=(0, ny, 0), segments=48, closed=True, rot=rot)
        for t_deg in (40.0 + 120.0 * k, 220.0 + 120.0 * k):
            t = math.radians(t_deg)
            p = rot @ Vector((12.5 * math.cos(t), 0.0, 12.5 * math.sin(t)))
            ellipsoid(electrons, (p.x, ny + p.y, p.z), (1.15, 1.15, 1.15), rings=6, segments=10)
    return m


BUILDERS = {
    "A10_Floor": build_floor,
    "A10_EntryArch": build_entry_arch,
    "A10_ReactorDome": build_reactor_dome,
    "A10_CoolingTower": build_cooling_tower,
    "A10_CoolingTower2": build_cooling_tower_2,
    "A10_TurbineHall": build_turbine_hall,
    "A10_PowerLines": build_power_lines,
    "A10_ControlTower": build_control_tower,
    "A10_FusionCore": build_fusion_core,
    "A10_ChiefEngineer": build_chief_engineer,
    "A10_GoldenAtom": build_golden_atom,
}
