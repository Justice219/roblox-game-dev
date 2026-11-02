"""
egg_shards.py — the generic hatch-cinematic overlay for EVERY egg (owner R49: "actually animate
the egg opening animation"). One shared model, tinted per egg at runtime, laid over any egg from
eggs.py (same 3.0-stud egg surface, same zig-zag crack seam):

    Shard1 .. Shard7    curved, thick shell chips sitting on the crack band. Hidden while the egg
                        is whole; at the burst they appear and fly off with spin + gravity.
                        tinted = True: the client paints them the egg's ShellTop colour.
    Crack1 .. Crack3    dark ink crack lines, revealed in three stages during the anticipation
                        wobble (stage 3 runs along the real ShellTop / ShellBottom seam, so the
                        cap visibly separates where the crack is).
    Crack1Glow ..       thin Neon cores riding on top of each ink line: the "light leaking
    Crack3Glow          through the cracks". tinted = True: the client paints them the hatched
                        pet's RARITY colour (a common shows a soft white-grey glow, a legendary
                        gold). Small Neon area only (owner R19: glows are soft accents).

Every piece follows the egg surface maths of eggs.py exactly (egg_frame / crack_phi), so the
overlay fits each area egg without per-egg variants. The Harvest Egg's pumpkin ribs sink up to
0.1 stud below this smooth surface in the rib valleys; the cracks sit proud enough to stay on top.

Coordinates: Roblox space, ORIGIN = ground point under the egg (egg bottom at y = 0), decorated
face toward -Z — identical to every egg model, so the client places this model at the egg's pivot.

Client contract (src/client/UI/Screens/EggHatch/HatchStage.luau + src/client/Pets/HatchAnim.luau):
    pieces "Shard<n>"     fly outward along their own offset direction (from the egg axis)
    pieces "Crack<k>"     stage k ink, "Crack<k>Glow" stage k glow (k = 1..3)

Build: /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only EggShards
"""

from __future__ import annotations

import math

from snkit.core import HAZARD_BLACK, WHITE, Model
from snkit.shapes import add_faces

from models._critter_kit import tube, tup
from models.eggs import CRACK_PHI, SEGMENTS, SHELL_T, crack_phi, egg_frame

BUDGET = 2400

# Ink line: tube radius / how far its centre sits outside the shell (studs).
INK_RADIUS = 0.042
INK_LIFT = 0.012
# Glow core: thinner, a little prouder, so it reads as a bright line between dark edges.
GLOW_RADIUS = 0.022
GLOW_LIFT = 0.036
# Shards float this far outside the shell (never coplanar with the shell skin: owner R18).
SHARD_LIFT = 0.024
# Neon crack glow colour in the manifest (the client tints it per rarity).
GLOW_WHITE = (236, 240, 255)

# Shard layout: (yaw centre deg, polar centre rad, half width deg, half height rad, seed).
# Front-heavy (the camera sees the -Z face) and alternating above / below the seam.
SHARDS = (
    (-4.0, CRACK_PHI + 0.14, 18.0, 0.2, 1),
    (48.0, CRACK_PHI - 0.12, 16.0, 0.18, 2),
    (-52.0, CRACK_PHI + 0.1, 17.0, 0.19, 3),
    (100.0, CRACK_PHI + 0.16, 15.0, 0.18, 4),
    (-104.0, CRACK_PHI - 0.1, 16.0, 0.17, 5),
    (154.0, CRACK_PHI + 0.08, 18.0, 0.19, 6),
    (-156.0, CRACK_PHI - 0.14, 15.0, 0.18, 7),
)


def _hash(seed: int, k: int) -> float:
    """Deterministic 0..1 noise (stable builds: same geometry -> same content hash -> no re-upload)."""
    x = math.sin(seed * 127.1 + k * 311.7) * 43758.5453
    return x - math.floor(x)


def _surface(yaw_deg: float, phi: float, lift: float):
    """(point, normal) on the egg skin, pushed `lift` studs outward along the normal."""
    p, n = egg_frame(yaw_deg, phi)
    return p + n * lift, n


def build_shard(piece, yaw_c: float, phi_c: float, half_yaw: float, half_phi: float, seed: int):
    """
    One curved, thick shell chip: a jagged 6-point outline (points + notches) in (yaw, phi) around
    the centre, a mid ring at half size so the chip follows the egg curvature, outer skin + inner
    skin (SHELL_T thick, like the real shell) + the broken rim between them. Closed solid (~48
    triangles).
    """
    n_pts = 6
    outline = []
    for k in range(n_pts):
        a = 2 * math.pi * k / n_pts + (_hash(seed, k) - 0.5) * 0.6
        # Alternate sharp points and notches: a broken shell chip, not a round pebble.
        r = (1.0 if k % 2 == 0 else 0.52) * (0.82 + 0.18 * _hash(seed, k + 17))
        outline.append((yaw_c + math.cos(a) * half_yaw * r, phi_c + math.sin(a) * half_phi * r))
    mid = [(yaw_c + (y - yaw_c) * 0.5, phi_c + (p - phi_c) * 0.5) for y, p in outline]

    def layer(inner: bool):
        pts = []
        for yaw, phi in [(yaw_c, phi_c)] + mid + outline:
            p, n = _surface(yaw, phi, SHARD_LIFT)
            if inner:
                p = p - n * SHELL_T
            pts.append(tup(p))
        return pts

    outer = layer(False)
    inner = layer(True)
    verts = outer + inner
    off = len(outer)
    faces = []
    # Index layout per skin: 0 = centre, 1..n = mid ring, n+1..2n = outline.
    for k in range(n_pts):
        k2 = (k + 1) % n_pts
        m1, m2 = 1 + k, 1 + k2
        o1, o2 = 1 + n_pts + k, 1 + n_pts + k2
        faces.append((0, m1, m2))
        faces.append((m1, o1, o2, m2))
        faces.append((off, off + m2, off + m1))
        faces.append((off + m1, off + m2, off + o2, off + o1))
        # Broken rim between the outer and inner outline.
        faces.append((o1, off + o1, off + o2, o2))
    # recalc_face_normals in snkit.export.realize orients the closed chip outward.
    add_faces(piece, verts, faces)


def _crack_line(ink, glow, points):
    """A crack polyline [(yaw deg, phi)] drawn as an ink tube with a glowing core on top."""
    ink_path = [tup(_surface(yaw, phi, INK_LIFT)[0]) for yaw, phi in points]
    glow_path = [tup(_surface(yaw, phi, GLOW_LIFT)[0]) for yaw, phi in points]
    # Taper both ends so the cracks look sharp, not like cut pipes.
    count = len(points)
    taper = [0.45 if i in (0, count - 1) else 1.0 for i in range(count)]
    tube(ink, ink_path, INK_RADIUS, sides=4, radii=[INK_RADIUS * t for t in taper])
    tube(glow, glow_path, GLOW_RADIUS, sides=4, radii=[GLOW_RADIUS * t for t in taper])


def _seam(yaw_from: float, yaw_to: float):
    """The real crack seam (eggs.py crack_phi zig-zag) between two yaws, column by column."""
    step = 360.0 / SEGMENTS
    pts = []
    s = math.ceil(yaw_from / step)
    while s * step <= yaw_to:
        pts.append((s * step, crack_phi(s % SEGMENTS)))
        s += 1
    return pts


def build_egg_shards():
    """The generic EggShards overlay (see the module docstring)."""
    m = Model(
        "EggShards",
        "ground point under the egg (bottom at y = 0), same frame as every eggs.py egg; front -Z; "
        "hatch overlay: Shard1..7 shell chips (tinted egg colour), Crack1..3 ink + Crack1..3Glow "
        "(tinted rarity colour) revealed in stages",
        budget=BUDGET,
    )
    for index, (yaw, phi, half_yaw, half_phi, seed) in enumerate(SHARDS, start=1):
        piece = m.piece(f"Shard{index}", WHITE, material="StudsSmall", tinted=True)
        build_shard(piece, yaw, phi, half_yaw, half_phi, seed)

    # Stage 1: the first crack on the front, a little left of centre (clear of front badges),
    # zig-zagging up from the seam, with one short branch.
    ink1 = m.piece("Crack1", HAZARD_BLACK, material="Smooth")
    glow1 = m.piece("Crack1Glow", GLOW_WHITE, material="Neon", tinted=True)
    _crack_line(ink1, glow1, [(-16, CRACK_PHI), (-10, 1.76), (-19, 1.9), (-11, 2.04), (-17, 2.17)])
    _crack_line(ink1, glow1, [(-19, 1.9), (-29, 1.97), (-33, 2.08)])
    _crack_line(ink1, glow1, [(-16, CRACK_PHI), (-21, 1.5), (-14, 1.4)])

    # Stage 2: the first crack grows; new cracks open on both front shoulders.
    ink2 = m.piece("Crack2", HAZARD_BLACK, material="Smooth")
    glow2 = m.piece("Crack2Glow", GLOW_WHITE, material="Neon", tinted=True)
    _crack_line(ink2, glow2, [(-17, 2.17), (-8, 2.3), (-15, 2.43), (-6, 2.55)])
    _crack_line(ink2, glow2, [(24, CRACK_PHI), (31, 1.75), (25, 1.88), (35, 2.02), (30, 2.14)])
    _crack_line(ink2, glow2, [(35, 2.02), (46, 2.08)])
    _crack_line(ink2, glow2, [(-48, CRACK_PHI), (-42, 1.47), (-50, 1.36)])

    # Stage 3: the crack runs along the real seam across the whole front + sides (where the cap
    # will separate), plus side branches.
    ink3 = m.piece("Crack3", HAZARD_BLACK, material="Smooth")
    glow3 = m.piece("Crack3Glow", GLOW_WHITE, material="Neon", tinted=True)
    _crack_line(ink3, glow3, _seam(-126.0, 126.0))
    _crack_line(ink3, glow3, [(72, CRACK_PHI + 0.11), (78, 1.86), (70, 1.98), (80, 2.1)])
    _crack_line(ink3, glow3, [(-90, CRACK_PHI + 0.11), (-84, 1.85), (-93, 1.97)])
    _crack_line(ink3, glow3, [(8, CRACK_PHI - 0.11), (4, 1.38), (11, 1.27)])
    return m


BUILDERS = {"EggShards": build_egg_shards}
