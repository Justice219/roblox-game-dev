"""
hub_moon_rocket.py — the cartoon MOON ROCKET portal (W9b, owner R70 "Moon Base"; spec
docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §2.3).

ONE model used in BOTH worlds, exactly like the Time Machine (hub_time_machine.py):
    * Nuke Town lobby  HubLayout.anchors.WorldPortals.moon       — the Sign reads "MOON BASE"
    * Moon Base hub    MoonHubLayout.anchors.ReturnPortal       — the Sign reads "BACK TO NUKE TOWN"
The sign text is NOT geometry: the `Sign` piece's Front face takes HubBuilder's SurfaceGui label
(sized from the layouts' `surfaces.Hub_MoonRocket` "Sign" entry), so one mesh serves both worlds.

    Hub_MoonRocket   a launch pad with a walk-through LAUNCH RING in front of a friendly rocket:
        Base     lilac launch-pad dais (30 x 26, top y = 1.0, centred z = +6) + a front step
                 (top y = 0.5) with a coral trim band
        Body     chrome-white launch ring (r 7.4-9.6, 2.4 deep, centre y 8.6, standing in the XY
                 plane, its bottom arc sunk into the dais) + the rocket's white fuselage behind it
                 (centre z = +9, r 5.0, y 5-30) and the sign frame
        Trim     coral: bezel lips on both ring faces, the rocket's nose cone + tip ball, the sign
                 posts and the dais trim band
        Band     violet bands round the fuselage, the porthole rims, the sign frame border
        Fins     three mint fins (left, right, back) standing on the dais: the rocket's legs
        Portal   deep-navy disc filling the ring (r 7.5), the engine bell under the fuselage and the
                 side / back porthole glass
        Swirl    two sunshine-yellow spiral arms + a four-point sparkle on both faces of the disc;
                 180° symmetric, so the piece's box centre IS the ring centre and WorldFx can spin it
                 about its local Z (WorldFxConfig Assemblies.Hub_MoonRocket.Swirl -> TimeSwirl)
        Porthole one warm Neon porthole above the sign (box 2.3 x 2.3: real Neon under the R19
                 6-stud² limit; WorldFx gives it a soft light via Assemblies.Hub_MoonRocket)
        Sign     cream panel 13.6 x 3.0, Front face z = -0.6 at y = 21.6 (SurfaceGui target)

Frame (Roblox space): pivot = ground centre under the ring (dais bottom y = 0), FRONT = -Z (the side
players walk in from and the sign faces), +X = the rocket's right-hand side (the viewer's LEFT). The
ring centre is (0, 8.6, 0); the walk-in opening is the ring's inside (bottom y 1.2, 0.2 above the
dais); the touch volume the layouts author is a 9 x 10 x 2.5 box at (0, 8.4, 0).

Layout constants (mirrored in src/shared/Config/HubLayout.luau and
src/shared/Config/Worlds/Moon/MoonHubLayout.luau "MOON_ROCKET"; tests/moon-hub-layout.luau asserts
the two collider lists are equal; change all three together):
    dais 30 x 1.0 x 26 at (0, 0.5, 6); step 22 x 0.5 x 3.2 at (0, 0.25, -8.4)
    ring centre y 8.6, inner r 7.4, outer r 9.6, depth 2.4; sign face centre (0, 21.6, -0.6)
    rocket axis (0, y, 9.0), fuselage r 5.0 (y 5-30), nose tip y 42.4 (+ ball to 44); fins reach r 9.5 from the axis

Budget: hero landmark <= 6,000 triangles (docs/world-art.md §4), built to ~3.8k / 9 pieces like the
Time Machine: it stands in the lobby's first-view pass (tests/hub-layout "hub lobby" budget).

Kid-friendly (spec §2.2 "Look"): a round toy rocket in candy colours, no flames, no exhaust.

Example (edit-mode preview):
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only Hub_MoonRocket
"""

from __future__ import annotations

import math

from snkit.core import Model
from snkit.kit import block
from snkit.shapes import add_faces, box, cylinder, ellipsoid, prism, revolve, ring_tube, rot_z

from models.hub import rrect_outline, slab

# ---- Palette (moon candy: chrome-white rocket, coral nose, mint fins, violet bands) ------------
PAD_LILAC = (126, 118, 186)  # launch-pad dais
CHROME = (236, 238, 248)  # ring + fuselage
CORAL = (255, 112, 96)  # nose, bezel lips, sign posts, trim
VIOLET = (150, 104, 232)  # fuselage bands, porthole rims, sign frame
MINT = (110, 226, 178)  # fins
PORTAL_NAVY = (60, 52, 150)  # swirl backing disc (a slice of night sky) + the engine bell
STAR_YELLOW = (255, 220, 80)  # spinning swirl arms
PORTHOLE = (255, 236, 160)  # warm Neon porthole (LAMP_WARM)
CREAM = (250, 232, 190)  # sign panel

# ---- Dimensions (mirrored in HubLayout.luau / MoonHubLayout.luau; change together) -------------
DAIS_W, DAIS_D, DAIS_CZ, DAIS_TOP = 30.0, 26.0, 6.0, 1.0
STEP_W, STEP_D, STEP_TOP, STEP_Z = 22.0, 3.2, 0.5, -8.4
RING_Y = 8.6  # ring centre height (opening bottom 1.2 = 0.2 above the dais)
R_IN, R_OUT = 7.4, 9.6  # ring body radii (opening = r < R_IN)
RING_DEPTH = 2.4  # z in [-1.2, 1.2]
PORTAL_R = 7.5  # backing disc reaches 0.1 into the ring body (no visible gap)
SIGN_Y, SIGN_W, SIGN_H = 21.6, 13.6, 3.0
SIGN_FRONT_Z = -0.6
ROCKET_Z = 9.0  # rocket axis (behind the ring: fuselage front z 4.0, ring back face z 1.2)
BODY_R = 5.0
BODY_Y0, BODY_Y1 = 5.0, 30.0
NOSE_TIP = 42.4
RING_SEGMENTS = 32


def _spiral_arm(piece, phase, z0, z1, steps=14, turns=1.1, r0=0.8, r1=7.0):
    """
    One spiral arm of the swirl lying in the plane z0..z1 (the Time Machine's arm, sized for the
    launch ring): a flat strip from radius r0 to r1 sweeping `turns` revolutions, widening toward the
    rim. One closed strip (front, back, inner and outer side quads + two end caps).
    """
    verts = []
    for i in range(steps + 1):
        t = i / steps
        ang = phase + 2 * math.pi * turns * t
        r = r0 + (r1 - r0) * t
        half = 0.2 + 0.55 * t
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
        faces.append((a + 0, a + 2, b + 2, b + 0))
        faces.append((a + 1, b + 1, b + 3, a + 3))
        faces.append((a + 0, b + 0, b + 1, a + 1))
        faces.append((a + 2, a + 3, b + 3, b + 2))
    last = steps * 4
    faces.append((0, 1, 3, 2))
    faces.append((last + 0, last + 2, last + 3, last + 1))
    add_faces(piece, verts, faces)


def _sparkle(piece, z0, z1, outer=1.6, inner=0.45):
    """Flat four-point sparkle centred on the ring axis (90° symmetric) between z0 and z1."""
    pts = []
    for i in range(8):
        r = outer if i % 2 == 0 else inner
        a = math.radians(90.0 + 45.0 * i)
        pts.append((math.cos(a) * r, RING_Y + math.sin(a) * r))
    zc = (z0 + z1) / 2
    prism(piece, [(x, y, zc) for x, y in pts], (0, 0, 1), z1 - z0)


def _fin(piece, angle_deg):
    """
    One mint fin on the rocket (axis (0, y, ROCKET_Z)), pointing out at `angle_deg` (0 = +Z, 90 =
    +X): a chunky swept trapezoid from the fuselage (y 6-17) out to r 9.5, its foot on the dais.
    """
    a = math.radians(angle_deg)
    ux, uz = math.sin(a), math.cos(a)
    # Outline in (radial distance, y): root along the body, swept tip down to the dais.
    outline = [(BODY_R - 0.4, 17.0), (BODY_R - 0.4, 6.0), (9.5, DAIS_TOP), (9.5, 4.6), (7.2, 11.5)]
    pts = [(ux * d, y, ROCKET_Z + uz * d) for d, y in outline]
    # Normal = the horizontal perpendicular of the fin direction.
    prism(piece, pts, (uz, 0.0, -ux), 1.0)


def build_moon_rocket():
    """
    The walk-through Moon Rocket portal (see the module docstring for pieces, frame and constants).
    @return Model "Hub_MoonRocket"
    """
    m = Model(
        "Hub_MoonRocket",
        "ground centre under the ring (bottom y = 0); FRONT -Z; ring centre (0, 8.6, 0); "
        "Sign Front face centre (0, 21.6, -0.6); rocket axis (0, y, 9)",
        budget=6000,
    )
    base = m.piece("Base", PAD_LILAC)
    body = m.piece("Body", CHROME)
    trim = m.piece("Trim", CORAL)
    band = m.piece("Band", VIOLET)
    fins = m.piece("Fins", MINT)
    portal = m.piece("Portal", PORTAL_NAVY)
    swirl = m.piece("Swirl", STAR_YELLOW, material="StudsSmall")
    porthole = m.piece("Porthole", PORTHOLE, material="Neon")
    sign = m.piece("Sign", CREAM)

    # ---- Launch-pad dais + front step (the step tucks 0.2 under the dais front: no shared faces) -
    slab(base, rrect_outline(DAIS_W, DAIS_D, 3.0, segments=3, cz=DAIS_CZ), 0.0, DAIS_TOP, chamfer=0.25)
    slab(base, rrect_outline(STEP_W, STEP_D, 1.0, segments=2, cz=STEP_Z), 0.0, STEP_TOP, chamfer=0.15)
    front = DAIS_CZ - DAIS_D / 2
    block(trim, (0.0, 0.62, front - 0.02), (DAIS_W - 6.4, 0.32, 0.24), bevel=0.06)
    for sx in (-1, 1):
        block(trim, (sx * (DAIS_W / 2 + 0.02), 0.62, DAIS_CZ), (0.24, 0.32, DAIS_D - 6.4), bevel=0.06)
    # Landing-light studs along the back edge of the pad (boxes in the trim piece: cheap, no draw call).
    for k in range(6):
        x = -11.0 + 22.0 * k / 5
        box(trim, (x, DAIS_TOP + 0.08, DAIS_CZ + DAIS_D / 2 - 1.2), (0.8, 0.16, 0.8))

    # ---- Launch ring: chrome body + coral bezel lips on both faces ------------------------------
    ring_tube(body, (0.0, RING_Y, 0.0), (R_IN + R_OUT) / 2, R_OUT - R_IN, RING_DEPTH, segments=RING_SEGMENTS, axis="Z")
    # Lips overhang the ring body by 0.1 on their free edge (outer 9.0-9.7, inner 7.3-7.8), so no lip
    # face is coplanar with the ring's own inner / outer surface (z-fight rule R18).
    for z in (-1.25, 1.25):
        ring_tube(trim, (0.0, RING_Y, z), 9.35, 0.7, 0.4, segments=RING_SEGMENTS, axis="Z")
        ring_tube(band, (0.0, RING_Y, z), 7.55, 0.5, 0.4, segments=RING_SEGMENTS, axis="Z")
    # Chunky mint bolts on the ring faces (both faces), every 60°, skipping the ones in the dais.
    for face_z, sz in ((-1.2, -1), (1.2, 1)):
        for k in range(6):
            a = math.radians(30 + 60 * k)
            x, y = math.sin(a) * 8.5, RING_Y + math.cos(a) * 8.5
            if y < DAIS_TOP + 1.0:
                continue
            box(fins, (x, y, face_z + sz * 0.3), (0.9, 0.9, 0.4), rot=rot_z(-math.degrees(a)))

    # ---- Portal disc + spinning star swirl (two arms per face, 180° apart: symmetric box) ------
    cylinder(portal, (0.0, RING_Y, -0.12), (0.0, RING_Y, 0.12), PORTAL_R, segments=RING_SEGMENTS)
    for z0, z1 in ((-0.38, -0.08), (0.08, 0.38)):
        for phase in (0.0, math.pi):
            _spiral_arm(swirl, phase, z0, z1)
    _sparkle(swirl, -0.46, -0.08)
    _sparkle(swirl, 0.08, 0.46)

    # ---- The rocket behind the ring ------------------------------------------------------------
    rc = (0.0, 0.0, ROCKET_Z)
    # Boat-tail + fuselage + ogive nose (one revolve each so the colour seams are real edges).
    revolve(body, [(0.0, BODY_Y0 - 0.4), (4.0, BODY_Y0 - 0.4), (BODY_R, BODY_Y0 + 1.6), (BODY_R, BODY_Y1), (0.0, BODY_Y1)], center=rc, segments=16)
    nose = [(BODY_R - 0.02, BODY_Y1 - 0.02), (4.7, BODY_Y1 + 3.0), (3.9, BODY_Y1 + 6.0), (2.6, BODY_Y1 + 9.0), (1.2, BODY_Y1 + 11.4), (0.0, NOSE_TIP)]
    revolve(trim, [(0.0, BODY_Y1 - 0.02)] + nose, center=rc, segments=16)
    ellipsoid(trim, (0.0, NOSE_TIP + 0.7, ROCKET_Z), (0.9, 0.9, 0.9), rings=4, segments=8)
    # Violet bands (proud of the fuselage by 0.15).
    for y in (11.0, 27.2):
        revolve(band, [(BODY_R + 0.15, y - 0.6), (BODY_R + 0.15, y + 0.6), (BODY_R - 0.2, y + 0.6), (BODY_R - 0.2, y - 0.6)], center=rc, segments=16, closed=True)
    # Engine bell (navy) under the boat-tail, its rim 0.6 above the dais.
    revolve(portal, [(1.6, BODY_Y0 - 0.3), (2.2, BODY_Y0 - 1.6), (3.0, DAIS_TOP + 0.6), (2.6, DAIS_TOP + 0.6), (1.4, BODY_Y0 - 1.5), (1.0, BODY_Y0 - 0.3)], center=rc, segments=16, closed=True)
    for angle in (90.0, 270.0, 0.0):
        _fin(fins, angle)

    # Front porthole above the sign (warm Neon, small) in a violet rim; side + back portholes are
    # violet rims round navy glass (the Portal piece: no extra draw call).
    pz = ROCKET_Z - BODY_R
    cylinder(band, (0.0, 33.4, pz + 0.55), (0.0, 33.4, pz - 0.25), 1.55, segments=16)
    cylinder(porthole, (0.0, 33.4, pz - 0.15), (0.0, 33.4, pz - 0.35), 1.15, segments=16)
    for angle in (60.0, 300.0, 180.0):
        a = math.radians(angle)
        ux, uz = math.sin(a), -math.cos(a)  # 180 = straight back (+Z); 60 / 300 = front-sides
        for y in (16.0,) if angle != 180.0 else (16.0, 21.0):
            c0 = (ux * (BODY_R - 0.5), y, ROCKET_Z + uz * (BODY_R - 0.5))
            c1 = (ux * (BODY_R + 0.25), y, ROCKET_Z + uz * (BODY_R + 0.25))
            c2 = (ux * (BODY_R + 0.3), y, ROCKET_Z + uz * (BODY_R + 0.3))
            cylinder(band, c0, c1, 1.25, segments=10)
            cylinder(portal, c1, c2, 0.9, segments=10)

    # ---- Sign on a violet frame, two coral posts down to the ring top ---------------------------
    block(band, (0.0, SIGN_Y, 0.0), (SIGN_W + 1.4, SIGN_H + 1.4, 0.8), bevel=0.2)
    block(sign, (0.0, SIGN_Y, SIGN_FRONT_Z + 0.15), (SIGN_W, SIGN_H, 0.3), bevel=0.05)
    for sx in (-1, 1):
        cylinder(trim, (sx * 3.4, RING_Y + R_OUT - 0.6, 0.0), (sx * 3.4, SIGN_Y - SIGN_H / 2 - 0.6, 0.0), 0.38, segments=8)
        ellipsoid(trim, (sx * (SIGN_W / 2 + 0.7), SIGN_Y + SIGN_H / 2 + 0.7, 0.0), (0.55, 0.55, 0.55), rings=4, segments=8)
    # Little star on top of the sign frame.
    pts = []
    for i in range(10):
        r = 1.3 if i % 2 == 0 else 0.55
        a = math.radians(90.0 + 36.0 * i)
        pts.append((math.cos(a) * r, SIGN_Y + SIGN_H / 2 + 0.7 + 1.3 + math.sin(a) * r, 0.0))
    prism(trim, pts, (0, 0, 1), 0.5)
    box(trim, (0.0, SIGN_Y + SIGN_H / 2 + 0.95, 0.0), (0.4, 0.5, 0.4))
    return m


BUILDERS = {"Hub_MoonRocket": build_moon_rocket}
