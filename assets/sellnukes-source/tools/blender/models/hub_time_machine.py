"""
hub_time_machine.py — the cartoon TIME MACHINE portal (W9 valley-hub-art, owner R57 "Dino Valley").

ONE model used in BOTH worlds (spec 2026-10-31-world2-design §4.4 / §16):
    * Nuke Town lobby  HubLayout.anchors.WorldPortals.dino  — the Sign reads "DINO VALLEY"
    * Dino Valley      ValleyLayout.anchors.ReturnPortal     — the Sign reads "BACK TO NUKE TOWN"
The sign text is NOT geometry: the `Sign` piece's Front face takes a SurfaceGui, so the same mesh
serves both worlds.

    Hub_TimeMachine   a giant stud-toy alarm clock you can walk through:
        Base     slate-purple rounded dais (32 x 14, top y = 1.0) + a front step (top y = 0.5)
        Body     purple clock ring (r 8.8-11.2, 3 deep, centre y = 10, standing in the XY plane,
                 its bottom arc sunk into the dais), the control console (left as seen from the
                 front) with a sloped dial panel, the lever pedestal (right) and the sign frame
        Rim      gold: front/back outer + inner lips of the ring (the clock bezel), two alarm bells
                 on legs at 10 and 2 o'clock, the sign posts, the 10:10 clock hands (both faces),
                 the lever shaft and a trim band round the dais
        Ticks    cream hour ticks on both ring faces (12/3/9 big, the bottom ones hidden in the dais
                 are skipped) + the three dial faces on the console
        Portal   deep-violet disc filling the ring (r 8.9, inside the ring's inner face)
        Swirl    two cyan spiral arms on both faces of the disc, rotationally symmetric about the
                 ring centre so the piece's box centre IS the ring centre: WorldFx spins it about
                 its local Z (needs the `Swirl` row: { motion = "spin", axis = "Z", speed = 90 })
        Knobs    red lever ball + dial pointers + console buttons
        Bulbs    three warm Neon bulbs on the console (one tight cluster: box 3.5 x 0.7 x 0.7, so it
                 stays real Neon under the R19 6-stud² limit)
        Sign     cream panel 13.6 x 3.0, Front face z = -0.6 at y = 24.8 (SurfaceGui target)

Frame (Roblox space): pivot = ground centre under the dais (dais bottom y = 0), FRONT = -Z (the
side players walk in from and the sign faces), +X = the machine's right-hand side (the viewer's
LEFT). The ring centre is (0, 10, 0); the walk-in opening is the ring's inside (bottom at y 1.2,
0.2 above the dais), the touch volume HubLayout / ValleyLayout author is a 10 x 12 x 2.5 box at
(0, 9.8, 0).

Layout constants (mirrored in src/shared/Config/HubLayout.luau and
src/shared/Config/Worlds/Dino/ValleyLayout.luau "TIME_MACHINE"; change all three together):
    dais 32 x 1.0 x 14 at (0, 0.5, 0); step 24 x 0.5 x 3.2 at (0, 0.25, -8.4)
    ring centre y 10, inner r 8.8, outer r 11.2, depth 3.0; sign face centre (0, 24.8, -0.6)
    console x [-15.8, -11.4]; lever pedestal x [12.0, 15.2]

Budget: hero landmark <= 6,000 triangles (docs/world-art.md §4); 9 pieces. It is in the lobby's
first-view pass (near the spawn), so it is kept lean (tests/hub-layout lobby budget).

Example (edit-mode preview):
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only Hub_TimeMachine
"""

from __future__ import annotations

import math

from snkit.core import LAMP_WARM, Model, TOY_RED
from snkit.kit import block
from snkit.shapes import add_faces, bar, box, cylinder, ellipsoid, prism, revolve, ring_tube, rot_z

from models.hub import rrect_outline, slab

# ---- Palette (time-machine candy: purple machine, gold bezel, violet/cyan swirl) ----------------
BASE_SLATE = (104, 86, 160)  # dais
MACHINE_PURPLE = (150, 96, 220)  # ring body, console, pedestal, sign frame
GOLD = (255, 196, 60)  # bezel lips, bells, hands, lever shaft, trims
CREAM = (250, 232, 190)  # ticks, dial faces, sign panel
PORTAL_VIOLET = (120, 80, 230)  # swirl backing disc
SWIRL_CYAN = (90, 230, 255)  # spinning arms

# ---- Dimensions (mirrored in HubLayout.luau / ValleyLayout.luau; change together) --------------
DAIS_W, DAIS_D, DAIS_TOP = 32.0, 14.0, 1.0
STEP_W, STEP_D, STEP_TOP, STEP_Z = 24.0, 3.2, 0.5, -8.4
RING_Y = 10.0  # ring centre height
R_IN, R_OUT = 8.8, 11.2  # ring body radii (opening = r < R_IN)
RING_DEPTH = 3.0  # z in [-1.5, 1.5]
PORTAL_R = 8.9  # backing disc reaches 0.1 into the ring body (no visible gap)
SIGN_Y, SIGN_W, SIGN_H = 24.8, 13.6, 3.0
SIGN_FRONT_Z = -0.6
RING_SEGMENTS = 40


def _clock_xy(angle_deg, radius, face):
    """
    Point on a clock face: `angle_deg` measured clockwise from 12 o'clock AS SEEN BY A VIEWER of
    that face. face = -1 for the front (viewer at -Z looking toward +Z: their right is model -X),
    +1 for the back (viewer at +Z: their right is model +X). Returns (x, y).
    """
    a = math.radians(angle_deg)
    return (face * math.sin(a) * radius, RING_Y + math.cos(a) * radius)


def _radial_block(piece, angle_deg, r0, r1, width, z0, z1, face):
    """A flat block from radius r0 to r1 along the clock direction `angle_deg` (ticks, hands)."""
    x0, y0 = _clock_xy(angle_deg, r0, face)
    x1, y1 = _clock_xy(angle_deg, r1, face)
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    # Rotation that maps local +Y onto the radial direction (roll about Z).
    roll = math.degrees(math.atan2(-dx, dy))
    box(piece, ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), (width, length, z1 - z0), rot=rot_z(roll))


def _spiral_arm(piece, phase, z0, z1, steps=24, turns=1.15, r0=0.9, r1=8.35):
    """
    One spiral arm of the portal swirl lying in the plane z0..z1: a flat strip from radius r0 to r1
    sweeping `turns` revolutions, widening toward the rim. Built as one closed strip (front, back,
    inner and outer side quads + two end caps), ~8 triangles per step.
    """
    verts = []
    for i in range(steps + 1):
        t = i / steps
        ang = phase + 2 * math.pi * turns * t
        r = r0 + (r1 - r0) * t
        half = 0.22 + 0.62 * t  # half width grows from 0.22 to 0.84
        # Centre-line point + in-plane normal (radial direction is a good enough strip normal).
        cx, cy = math.cos(ang) * r, RING_Y + math.sin(ang) * r
        nx, ny = math.cos(ang), math.sin(ang)
        for side in (-1, 1):
            px, py = cx + nx * half * side, cy + ny * half * side
            verts.append((px, py, z0))
            verts.append((px, py, z1))
    faces = []
    for i in range(steps):
        a = i * 4
        b = a + 4
        # vertex order per step: [inner z0, inner z1, outer z0, outer z1]
        faces.append((a + 0, a + 2, b + 2, b + 0))  # z0 face
        faces.append((a + 1, b + 1, b + 3, a + 3))  # z1 face
        faces.append((a + 0, b + 0, b + 1, a + 1))  # inner side
        faces.append((a + 2, a + 3, b + 3, b + 2))  # outer side
    last = steps * 4
    faces.append((0, 1, 3, 2))
    faces.append((last + 0, last + 2, last + 3, last + 1))
    add_faces(piece, verts, faces)


def build_time_machine():
    """
    The walk-through Time Machine (see the module docstring for pieces, frame and constants).
    @return Model "Hub_TimeMachine"
    """
    m = Model(
        "Hub_TimeMachine",
        "ground centre under the dais (bottom y = 0); FRONT -Z; ring centre (0, 10, 0); "
        "Sign Front face centre (0, 24.8, -0.6)",
        budget=6000,
    )
    base = m.piece("Base", BASE_SLATE)
    body = m.piece("Body", MACHINE_PURPLE)
    rim = m.piece("Rim", GOLD)
    ticks = m.piece("Ticks", CREAM, material="StudsSmall")
    portal = m.piece("Portal", PORTAL_VIOLET)
    swirl = m.piece("Swirl", SWIRL_CYAN, material="StudsSmall")
    knobs = m.piece("Knobs", TOY_RED, material="StudsSmall")
    bulbs = m.piece("Bulbs", LAMP_WARM, material="Neon")
    sign = m.piece("Sign", CREAM)

    # ---- Dais + front step (the step tucks 0.2 under the dais front so no faces coincide) -------
    slab(base, rrect_outline(DAIS_W, DAIS_D, 2.0, segments=3), 0.0, DAIS_TOP, chamfer=0.25)
    slab(base, rrect_outline(STEP_W, STEP_D, 1.0, segments=2, cz=STEP_Z), 0.0, STEP_TOP, chamfer=0.15)
    # Gold trim band on the dais front + sides (proud of the faces by 0.1).
    block(rim, (0.0, 0.62, -DAIS_D / 2 - 0.02), (DAIS_W - 4.4, 0.32, 0.24), bevel=0.06)
    for sx in (-1, 1):
        block(rim, (sx * (DAIS_W / 2 + 0.02), 0.62, 0.0), (0.24, 0.32, DAIS_D - 4.4), bevel=0.06)

    # ---- Clock ring: purple body + gold bezel lips on both faces -------------------------------
    ring_tube(body, (0.0, RING_Y, 0.0), (R_IN + R_OUT) / 2, R_OUT - R_IN, RING_DEPTH, segments=RING_SEGMENTS, axis="Z")
    for z in (-1.55, 1.55):
        ring_tube(rim, (0.0, RING_Y, z), 10.9, 0.8, 0.5, segments=RING_SEGMENTS, axis="Z")
        ring_tube(rim, (0.0, RING_Y, z), 9.0, 0.6, 0.5, segments=RING_SEGMENTS, axis="Z")

    # Hour ticks between the lips (r 9.35-10.45), both faces; skip the ones sunk in the dais.
    for face, z0, z1 in ((-1, -1.68, -1.42), (1, 1.42, 1.68)):
        for k in range(12):
            angle = 30 * k
            _, y_low = _clock_xy(angle, 10.45, face)
            if y_low < DAIS_TOP + 0.8:
                continue
            big = k % 3 == 0
            _radial_block(ticks, angle, 9.35, 10.45, 0.95 if big else 0.55, z0, z1, face)

    # ---- Portal disc + spinning swirl (two arms per face, 180° apart: symmetric box) ------------
    cylinder(portal, (0.0, RING_Y, -0.12), (0.0, RING_Y, 0.12), PORTAL_R, segments=RING_SEGMENTS)
    for z0, z1 in ((-0.38, -0.08), (0.08, 0.38)):
        for phase in (0.0, math.pi):
            _spiral_arm(swirl, phase, z0, z1)

    # ---- 10:10 hands in front of the swirl on both faces + a gold hub cap -----------------------
    for face, z0, z1 in ((-1, -0.72, -0.46), (1, 0.46, 0.72)):
        _radial_block(rim, 300, 0.0, 4.6, 0.75, z0, z1, face)  # hour hand -> 10
        _radial_block(rim, 60, 0.0, 6.8, 0.5, z0, z1, face)  # minute hand -> 2
    cylinder(rim, (0.0, RING_Y, -0.86), (0.0, RING_Y, 0.86), 0.85, segments=12)

    # ---- Alarm bells at 10 and 2 o'clock on short gold legs ------------------------------------
    for sx in (-1, 1):
        tilt = 40.0
        a = math.radians(tilt)
        leg0 = (sx * math.sin(a) * (R_OUT - 0.3), RING_Y + math.cos(a) * (R_OUT - 0.3), 0.0)
        leg1 = (sx * math.sin(a) * (R_OUT + 1.2), RING_Y + math.cos(a) * (R_OUT + 1.2), 0.0)
        cylinder(rim, leg0, leg1, 0.32, segments=8)
        # Bell dome, axis tilted outward with the leg (revolve about local Y, rolled by -sx*tilt).
        profile = [(0.0, 2.3), (0.9, 2.15), (1.7, 1.55), (2.15, 0.7), (2.3, 0.1), (2.0, 0.0), (0.0, 0.0)]
        revolve(rim, profile, center=leg1, segments=16, rot=rot_z(-sx * tilt))
        # Clapper ball peeking out under the bell rim.
        ellipsoid(knobs, (leg1[0] - sx * 0.2, leg1[1] - 0.15, 0.0), (0.45, 0.45, 0.45), rings=4, segments=8)

    # ---- Sign on a purple frame, two gold posts down to the ring top ---------------------------
    block(body, (0.0, SIGN_Y, 0.0), (SIGN_W + 1.4, SIGN_H + 1.4, 0.8), bevel=0.2)
    block(sign, (0.0, SIGN_Y, SIGN_FRONT_Z + 0.15), (SIGN_W, SIGN_H, 0.3), bevel=0.05)
    for sx in (-1, 1):
        cylinder(rim, (sx * 3.6, RING_Y + R_OUT - 0.6, 0.0), (sx * 3.6, SIGN_Y - SIGN_H / 2 - 0.6, 0.0), 0.4, segments=8)
        ellipsoid(rim, (sx * (SIGN_W / 2 + 0.7), SIGN_Y + SIGN_H / 2 + 0.7, 0.0), (0.55, 0.55, 0.55), rings=4, segments=8)

    # ---- Control console (machine's left = model -X) with a sloped dial panel ------------------
    cx0, cx1 = -15.8, -11.4
    outline = [(2.4, DAIS_TOP), (2.4, 7.3), (-0.6, 6.4), (-2.4, 5.3), (-2.4, DAIS_TOP)]
    prism(body, [((cx0 + cx1) / 2, y, z) for z, y in outline], (1, 0, 0), cx1 - cx0)
    # Panel normal (up + toward the front) of the slope from (z 2.4, y 7.3) to (z -2.4, y 5.3).
    slope = math.atan2(7.3 - 5.3, 2.4 - (-2.4))
    nrm = (0.0, math.cos(slope), -math.sin(slope))
    for i, x in enumerate((-14.9, -13.6, -12.3)):
        cz = 0.0
        cy = 5.3 + (cz + 2.4) / 4.8 * 2.0
        c0 = (x, cy - nrm[1] * 0.05, cz - nrm[2] * 0.05)
        c1 = (x, cy + nrm[1] * 0.22, cz + nrm[2] * 0.22)
        cylinder(ticks, c0, c1, 0.52, segments=12)
        # Pointer: a red needle lying on the dial face, each at a different angle.
        tip_a = math.radians(-50 + 50 * i)
        px, pz = math.sin(tip_a) * 0.42, math.cos(tip_a) * 0.42 * math.cos(slope)
        p0 = (x, cy + nrm[1] * 0.3, cz + nrm[2] * 0.3)
        p1 = (x + px, p0[1] + math.sin(slope) * 0.42 * math.cos(tip_a), p0[2] + pz)
        bar(knobs, p0, p1, 0.12)
    # Buttons on the lower front of the console.
    for x in (-14.6, -12.6):
        cylinder(knobs, (x, 3.4, -2.42), (x, 3.4, -2.72), 0.38, segments=10)
    # Neon bulb cluster on the console's back edge (one small box: real Neon under the R19 limit).
    for x in (-14.9, -13.6, -12.3):
        ellipsoid(bulbs, (x, 7.55, 1.9), (0.34, 0.34, 0.34), rings=4, segments=8)

    # ---- Lever (machine's right = model +X): purple pedestal, gold shaft, red ball -------------
    block(body, (13.6, DAIS_TOP + 1.8, 0.0), (3.2, 3.6, 3.2), bevel=0.3)
    block(rim, (13.6, DAIS_TOP + 3.65, 0.0), (2.2, 0.2, 2.2), bevel=0.06)
    top = (13.6, DAIS_TOP + 3.7, 0.0)
    end = (13.6, DAIS_TOP + 8.0, -2.3)
    cylinder(rim, top, end, 0.3, segments=8)
    ellipsoid(knobs, end, (0.85, 0.85, 0.85), rings=5, segments=10)
    return m


BUILDERS = {"Hub_TimeMachine": build_time_machine}
