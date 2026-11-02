"""
_critter_kit.py — shared modelling helpers for the B8f art set (pets, eggs, crates, attack mode,
Harvest Feast event items). PRIVATE helper module: the leading underscore keeps it out of
generate_world.py's builder auto-discovery (`[a-z][a-z0-9_]*` module names only), so it never needs
a BUILDERS table; pets.py / eggs.py / crates.py / attack.py / event_items.py import it.

Everything is ROBLOX space (studs, +Y up, model front = -Z, +X = the model's right-hand side), like
the rest of snkit. Helpers append into snkit Pieces, so callers choose the colour grouping.

What lives here (and why it is not in snkit): these are "cute critter" primitives — oriented
ellipsoids for eyes / ears / paws, points on an ellipsoid surface for placing face features,
closed tubes for orbit rings / tails, a smile arc, five-point stars, a crown and a whole-model
re-orientation. snkit is owned by the pipeline builder (B4); keeping these here avoids editing a
shared module while six art builders run in parallel.

Example:
    from models._critter_kit import surface, oriented_ellipsoid, eyes, orbit_ring
    head_c, head_r = (0, 1.3, -0.1), (0.8, 0.7, 0.7)
    ellipsoid(head, head_c, head_r, rings=10, segments=16)
    eyes(face, shine, head_c, head_r, yaw=26, pitch=6, size=0.16)
    orbit_ring(glow, (0, 1.3, -0.1), 1.1, 0.05, tilt_x=20, tilt_z=-25)
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import br, rb
from snkit.shapes import add_faces, ellipsoid, prism

# Extra toy colours used only by the B8f set (the shared palette lives in snkit.core).
GOLD = (255, 196, 46)
GOLD_DARK = (214, 150, 30)
BLUSH = (255, 150, 170)
NAVY = (40, 52, 110)
SILVER = (208, 214, 226)
TURKEY_BROWN = (150, 92, 52)
BURNT_ORANGE = (230, 112, 38)
WATTLE_RED = (226, 54, 64)
ICE_BLUE = (150, 220, 255)
LAVENDER = (190, 150, 255)
TEAL = (40, 190, 180)
SOFT_BLACK = (36, 36, 46)
SNOW = (252, 252, 255)
CHOCOLATE = (98, 62, 42)
HOT_PINK = (255, 80, 160)
MAGENTA = (220, 70, 220)
SKY_GLOW = (120, 230, 255)
SUN_GLOW = (255, 230, 90)
EMBER = (255, 120, 50)
PLUM = (110, 60, 170)


def v3(p) -> Vector:
    """Tuple/Vector -> new mathutils Vector (3-D)."""
    return Vector((p[0], p[1], p[2]))


def tup(v) -> tuple:
    """Vector -> plain tuple (what the snkit helpers expect)."""
    return (v[0], v[1], v[2])


def direction(yaw: float, pitch: float) -> Vector:
    """
    Unit direction in Roblox space. yaw 0 = straight ahead (-Z, the model's front), positive yaw
    turns toward +X (the model's right); pitch positive = up.

    Example: direction(0, 0) -> (0, 0, -1); direction(90, 0) -> (1, 0, 0)
    """
    y, p = math.radians(yaw), math.radians(pitch)
    return Vector((math.sin(y) * math.cos(p), math.sin(p), -math.cos(y) * math.cos(p)))


def surface(center, radii, yaw: float, pitch: float):
    """
    Point and outward normal on an axis-aligned ellipsoid, hit along direction(yaw, pitch) from its
    centre. Used to stick eyes, ears and badges onto a head/body without guessing coordinates.

    Returns (point: Vector, normal: Vector).
    """
    d = direction(yaw, pitch)
    a, b, c = radii
    t = 1.0 / math.sqrt((d.x / a) ** 2 + (d.y / b) ** 2 + (d.z / c) ** 2)
    local = d * t
    point = v3(center) + local
    normal = Vector((local.x / (a * a), local.y / (b * b), local.z / (c * c))).normalized()
    return point, normal


def frame(normal, up=(0, 1, 0)):
    """
    Right-handed frame (side, up, normal) with `normal` as local Z. `up` is orthogonalised against
    the normal (falls back to +X when they are parallel).
    """
    n = v3(normal).normalized()
    u = v3(up)
    u = u - n * u.dot(n)
    if u.length < 1e-5:
        u = Vector((1, 0, 0)) - n * n.x
    u.normalize()
    s = u.cross(n).normalized()
    return s, u, n


def oriented_ellipsoid(piece, center, radii, normal=(0, 0, -1), up=(0, 1, 0), rings=6, segments=10):
    """
    Ellipsoid whose local X/Y/Z radii follow the frame(normal, up): radii[2] is the thickness
    along `normal`. Eyes, cheeks, flat paws, ear pads and badges are all squashed ellipsoids that
    face outward from a surface.
    """
    s, u, n = frame(normal, up)

    def deform(x, y, z):
        p = s * x + u * y + n * z
        return (p.x, p.y, p.z)

    ellipsoid(piece, center, radii, rings=rings, segments=segments, deform=deform)


def plate(piece, outline_2d, origin, normal, up=(0, 1, 0), thickness=0.1):
    """
    Flat shape (ear, wing, feather, fin, star) from a 2-D outline [(x, y)] drawn in the frame
    (side, up) at `origin`, extruded symmetrically along `normal` by `thickness`.
    Concave outlines are fine: Blender's ngon triangulation handles simple polygons.
    """
    s, u, n = frame(normal, up)
    o = v3(origin)
    pts = [tup(o + s * x + u * y) for x, y in outline_2d]
    prism(piece, pts, tup(n), thickness)


def tube(piece, path, radius, sides=6, closed=False, radii=None):
    """
    Tube along a polyline of Roblox points (tails, smiles, horns, orbit rings). `radii` may give a
    radius per point (tapering horns / tails). Open tubes get flat end caps. Frames are propagated
    along the path (parallel transport), so the tube never twists.
    """
    pts = [v3(p) for p in path]
    count = len(pts)
    if count < 2:
        return
    rads = radii if radii is not None else [radius] * count
    tangents = []
    for i in range(count):
        if closed:
            t = pts[(i + 1) % count] - pts[(i - 1) % count]
        else:
            t = pts[min(i + 1, count - 1)] - pts[max(i - 1, 0)]
        tangents.append(t.normalized())
    # Initial normal: any vector perpendicular to the first tangent.
    ref = Vector((0, 1, 0)) if abs(tangents[0].y) < 0.9 else Vector((1, 0, 0))
    nrm = (ref - tangents[0] * ref.dot(tangents[0])).normalized()
    verts = []
    for i in range(count):
        t = tangents[i]
        nrm = (nrm - t * nrm.dot(t))
        if nrm.length < 1e-6:
            nrm = (ref - t * ref.dot(t))
        nrm.normalize()
        bin_ = t.cross(nrm).normalized()
        for k in range(sides):
            a = 2 * math.pi * k / sides
            p = pts[i] + (nrm * math.cos(a) + bin_ * math.sin(a)) * rads[i]
            verts.append(tup(p))
    faces = []
    rings = count if closed else count - 1
    for i in range(rings):
        a = i * sides
        b = ((i + 1) % count) * sides
        for k in range(sides):
            k2 = (k + 1) % sides
            faces.append((a + k, a + k2, b + k2, b + k))
    if not closed:
        faces.append(tuple(range(sides - 1, -1, -1)))
        last = (count - 1) * sides
        faces.append(tuple(range(last, last + sides)))
    add_faces(piece, verts, faces)


def circle_points(center, radius, normal=(0, 1, 0), segments=24, up=(0, 0, -1), squash=1.0):
    """Points of a circle (or ellipse with `squash` on the second axis) in the plane ⟂ normal."""
    s, u, _ = frame(normal, up)
    c = v3(center)
    return [
        tup(c + s * (radius * math.cos(2 * math.pi * i / segments)) + u * (radius * squash * math.sin(2 * math.pi * i / segments)))
        for i in range(segments)
    ]


def tilted_normal(tilt_x: float, tilt_z: float) -> tuple:
    """+Y tipped by tilt_x degrees about X then tilt_z degrees about Z (orbit-ring planes)."""
    ax, az = math.radians(tilt_x), math.radians(tilt_z)
    y = Vector((0, math.cos(ax), math.sin(ax)))
    y = Vector((y.x * math.cos(az) - y.y * math.sin(az), y.x * math.sin(az) + y.y * math.cos(az), y.z))
    return tup(y.normalized())


def orbit_ring(piece, center, radius, thickness, tilt_x=0.0, tilt_z=0.0, segments=24, sides=5, electrons=0, electron_r=0.12):
    """
    Cartoon atom orbit: a thin closed tube ring tilted off horizontal, with `electrons` little
    balls riding on it (same piece). Two or three rings at different tilts make the classic atom.
    """
    n = tilted_normal(tilt_x, tilt_z)
    pts = circle_points(center, radius, normal=n, segments=segments)
    tube(piece, pts, thickness, sides=sides, closed=True)
    for e in range(electrons):
        p = pts[(e * segments) // max(electrons, 1) + segments // 8]
        ellipsoid(piece, p, (electron_r, electron_r, electron_r), rings=4, segments=8)


def smile(piece, center, radii, pitch=-12.0, width=14.0, depth=4.0, thickness=0.035, steps=6):
    """
    Little smile arc on an ellipsoid face: points sampled from yaw -width..+width with the middle
    dipping `depth` degrees lower, pushed just outside the surface, joined by a thin tube.
    """
    path = []
    for i in range(steps + 1):
        t = i / steps
        yaw = -width + 2 * width * t
        dip = depth * (1 - (2 * t - 1) ** 2)
        p, n = surface(center, radii, yaw, pitch - dip)
        path.append(tup(p + n * thickness * 0.4))
    tube(piece, path, thickness, sides=5)


def eyes(face, shine, center, radii, yaw=24.0, pitch=8.0, size=0.16, tall=1.25, sink=0.035, shine_size=0.36):
    """
    Two big glossy toy eyes on an ellipsoid head: dark squashed ellipsoids (face piece) with a
    white highlight dot up-and-outward on each (shine piece). Pass shine=None to skip highlights.
    """
    for side in (-1, 1):
        p, n = surface(center, radii, side * yaw, pitch)
        c = p - n * sink
        oriented_ellipsoid(face, tup(c), (size, size * tall, size * 0.5), normal=tup(n), rings=6, segments=12)
        if shine is not None:
            s_, u_, n_ = frame(n)
            sp = c + n_ * (size * 0.36) + u_ * (size * 0.42) + s_ * (side * -size * 0.28)
            r = size * shine_size
            oriented_ellipsoid(shine, tup(sp), (r, r, r * 0.5), normal=tup(n), rings=4, segments=8)


def star_outline(outer: float, inner: float, points=5, rotate=90.0):
    """2-D five-point star outline (x, y), first point straight up by default."""
    out = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        a = math.radians(rotate + 180.0 * i / points)
        out.append((r * math.cos(a), r * math.sin(a)))
    return out


def star(piece, center, outer, thickness, normal=(0, 0, -1), up=(0, 1, 0), inner_ratio=0.48):
    """Chunky five-point star plate facing `normal` (confetti, egg decals, crowns, sparkles)."""
    plate(piece, star_outline(outer, outer * inner_ratio), center, normal, up, thickness)


def heart_outline(size: float, steps=10):
    """2-D cartoon heart outline (x, y), point down, centred near the origin."""
    pts = []
    for i in range(steps * 2):
        t = math.pi * 2 * i / (steps * 2)
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((x / 17 * size, y / 17 * size))
    return pts


def crown(band, gems, center, radius, height, points=5, segments=20):
    """
    Toy crown: a thick open band (outer + inner wall joined by rims) with `points` triangular
    spikes, each tipped with a gem ball (gems piece). center = band bottom centre; the first spike
    faces the model front (-Z).
    """
    cx, cy, cz = center
    band_h = height * 0.45
    r_in = radius * 0.82
    verts = []
    for r in (radius, r_in):
        for y in (cy, cy + band_h):
            for i in range(segments):
                a = 2 * math.pi * i / segments
                verts.append((cx + r * math.cos(a), y, cz + r * math.sin(a)))
    s_ = segments
    faces = []
    for i in range(s_):
        j = (i + 1) % s_
        faces.append((i, j, s_ + j, s_ + i))  # outer wall
        faces.append((2 * s_ + j, 2 * s_ + i, 3 * s_ + i, 3 * s_ + j))  # inner wall
        faces.append((s_ + i, s_ + j, 3 * s_ + j, 3 * s_ + i))  # top rim
        faces.append((j, i, 2 * s_ + i, 2 * s_ + j))  # bottom rim
    add_faces(band, verts, faces)
    spike_h = height - band_h * 0.6
    for k in range(points):
        a = 2 * math.pi * k / points - math.pi / 2
        dx, dz = math.cos(a), math.sin(a)
        base = Vector((cx + dx * radius * 0.91, cy + band_h * 0.6, cz + dz * radius * 0.91))
        w = 2 * math.pi * radius / points * 0.4
        plate(band, [(-w, 0), (w, 0), (0, spike_h)], tup(base), (dx, 0, dz), (0, 1, 0), radius * 0.16)
        g = radius * 0.15
        ellipsoid(gems, tup(base + Vector((0, spike_h, 0))), (g, g, g), rings=4, segments=8)


def transform_model(model, mat3=None, offset=(0.0, 0.0, 0.0), scale=1.0):
    """
    Re-orient / move / scale every piece of a finished model in Roblox space:
    p' = mat3 @ (p * scale) + offset. Used e.g. to build a projectile nose-up with snkit.nuke_body
    and then lay it nose-forward (-Z) for CFrame.lookAt flight.
    """
    off = v3(offset)
    for piece in model.pieces.values():
        for vert in piece.bm.verts:
            p = v3(br(vert.co)) * scale
            if mat3 is not None:
                p = mat3 @ p
            vert.co = rb(p + off)


def model_bounds(model):
    """(lo, hi) Roblox-space corners over every vertex of every piece (pre-realize)."""
    lo = [1e9, 1e9, 1e9]
    hi = [-1e9, -1e9, -1e9]
    for piece in model.pieces.values():
        for vert in piece.bm.verts:
            p = br(vert.co)
            for i in range(3):
                lo[i] = min(lo[i], p[i])
                hi[i] = max(hi[i], p[i])
    return lo, hi


def fmt_point(p) -> str:
    """Compact '(x,y,z)' with 2 decimals for pivot strings (joints, hinges)."""
    return "(" + ",".join(f"{c:.2f}".rstrip("0").rstrip(".") if abs(c) > 1e-9 else "0" for c in p) + ")"


def joints_text(joints: dict) -> str:
    """'joints Head@(0,1.3,-0.1) Tail@(0,0.7,0.6)' — machine-parsable joint list for pivot strings."""
    if not joints:
        return "joints none"
    return "joints " + " ".join(f"{name}@{fmt_point(p)}" for name, p in joints.items())


def catmull(points, per=4):
    """
    Smooth a control polyline with a Catmull-Rom spline (`per` samples per segment), for tails,
    tentacles, horns and feathers. End points are kept exactly.

    Example: catmull([(0,0,0), (0,1,1), (0,2,1)], per=3) -> 7 points
    """
    pts = [v3(p) for p in points]
    if len(pts) < 3:
        return [tup(p) for p in pts]
    ext = [pts[0] * 2 - pts[1]] + pts + [pts[-1] * 2 - pts[-2]]
    out = []
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        for k in range(per):
            t = k / per
            t2, t3 = t * t, t * t * t
            q = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
            out.append(tup(q))
    out.append(tup(pts[-1]))
    return out
