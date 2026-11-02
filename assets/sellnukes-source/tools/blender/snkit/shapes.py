"""
snkit.shapes — low-level mesh primitives, all inputs in ROBLOX space (studs, +Y up, front -Z).

Ported from RoBeasts generate_models.py (box/bar/cylinder/ellipsoid/prism/revolve/ring_tube/loft)
with SellNukes additions: `segments` on box bevels, `clip_convex` (2-D Sutherland-Hodgman, used to
cut diagonal hazard stripes to a tile), `extrude_outline` (a flat 2-D outline on the XZ ground
plane extruded up, used for stripes, road lines and signs).

Every helper appends geometry to a Piece's bmesh; normals are recalculated in snkit.export.realize,
so winding here only needs to be consistent, not perfect.

Example:
    box(piece, (0, 0.5, 0), (4, 1, 4), bevel=0.15)        # 4x1x4 slab, chamfered edges
    cylinder(piece, (0, 0, 0), (0, 3, 0), 0.5, segments=12)
"""

from __future__ import annotations

import math

import bmesh
from mathutils import Matrix, Vector

from .core import rb


def add_faces(piece, verts_rb, faces):
    """Add Roblox-space vertices + index faces to the piece; duplicate faces are skipped."""
    bm = piece.bm
    made = [bm.verts.new(rb(v)) for v in verts_rb]
    for face in faces:
        try:
            bm.faces.new([made[i] for i in face])
        except ValueError:
            pass
    return made


def frame_from(axis_x, axis_y) -> Matrix:
    """3x3 rotation (Roblox space) whose columns are the given X and Y axes (Z = X x Y)."""
    x = Vector(axis_x).normalized()
    y = Vector(axis_y).normalized()
    z = x.cross(y)
    return Matrix((x, y, z)).transposed()


def rot_y(degrees: float) -> Matrix:
    """Rotation about Roblox +Y (yaw). Positive = counter-clockwise seen from above."""
    r = math.radians(degrees)
    c, s = math.cos(r), math.sin(r)
    return Matrix(((c, 0, s), (0, 1, 0), (-s, 0, c)))


def rot_x(degrees: float) -> Matrix:
    """Rotation about Roblox +X (pitch)."""
    r = math.radians(degrees)
    c, s = math.cos(r), math.sin(r)
    return Matrix(((1, 0, 0), (0, c, -s), (0, s, c)))


def rot_z(degrees: float) -> Matrix:
    """Rotation about Roblox +Z (roll)."""
    r = math.radians(degrees)
    c, s = math.cos(r), math.sin(r)
    return Matrix(((c, -s, 0), (s, c, 0), (0, 0, 1)))


def box(piece, center, size, rot=None, bevel=0.0, segments=1):
    """
    Axis-aligned (or rotated) box. `bevel` chamfers every edge by that many studs; segments=1 gives
    a crisp toy chamfer (cheapest: +18 quads), 2 a rounder edge. Keep bevels <= 0.2 * smallest side.
    """
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    corners = [
        (-hx, -hy, -hz),
        (hx, -hy, -hz),
        (hx, hy, -hz),
        (-hx, hy, -hz),
        (-hx, -hy, hz),
        (hx, -hy, hz),
        (hx, hy, hz),
        (-hx, hy, hz),
    ]
    points = []
    for c in corners:
        v = Vector(c)
        if rot is not None:
            v = rot @ v
        points.append((center[0] + v.x, center[1] + v.y, center[2] + v.z))
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    made = add_faces(piece, points, faces)
    if bevel > 0:
        edges = list({e for v in made for e in v.link_edges})
        bmesh.ops.bevel(
            piece.bm,
            geom=edges,
            offset=bevel,
            offset_type="OFFSET",
            segments=segments,
            profile=0.5,
            affect="EDGES",
            clamp_overlap=True,
        )
    return made


def bar(piece, a, b, thickness, bevel=0.0):
    """Square-section bar between two Roblox points (truss members, handles, legs)."""
    a, b = Vector(a), Vector(b)
    d = b - a
    length = d.length
    if length < 1e-4:
        return
    z = d.normalized()
    up = Vector((0, 1, 0)) if abs(z.y) < 0.95 else Vector((1, 0, 0))
    x = up.cross(z).normalized()
    y = z.cross(x)
    rot = Matrix((x, y, z)).transposed()
    mid = (a + b) / 2
    box(piece, (mid.x, mid.y, mid.z), (thickness, thickness, length), rot, bevel=bevel)


def cylinder(piece, a, b, radius, segments=16, radius_b=None):
    """Closed cylinder (or cone frustum when radius_b differs) from point a to point b."""
    a, b = Vector(a), Vector(b)
    d = b - a
    if d.length < 1e-4:
        return
    z = d.normalized()
    up = Vector((0, 1, 0)) if abs(z.y) < 0.95 else Vector((1, 0, 0))
    x = up.cross(z).normalized()
    y = z.cross(x)
    r_b = radius if radius_b is None else radius_b
    points = []
    for end, r in ((a, radius), (b, r_b)):
        for i in range(segments):
            t = 2 * math.pi * i / segments
            p = end + (x * math.cos(t) + y * math.sin(t)) * r
            points.append((p.x, p.y, p.z))
    faces = [tuple(range(segments - 1, -1, -1)), tuple(range(segments, 2 * segments))]
    for i in range(segments):
        j = (i + 1) % segments
        faces.append((i, j, segments + j, segments + i))
    add_faces(piece, points, faces)


def ellipsoid(piece, center, radii, rings=8, segments=12, deform=None):
    """Closed UV ellipsoid; `deform(x, y, z)` (local Roblox coords) may reshape each vertex."""
    points = [(0.0, radii[1], 0.0)]
    for r in range(1, rings):
        phi = math.pi * r / rings
        for s in range(segments):
            theta = 2 * math.pi * s / segments
            points.append(
                (
                    radii[0] * math.sin(phi) * math.cos(theta),
                    radii[1] * math.cos(phi),
                    radii[2] * math.sin(phi) * math.sin(theta),
                )
            )
    points.append((0.0, -radii[1], 0.0))
    if deform is not None:
        points = [deform(*p) for p in points]
    points = [(center[0] + p[0], center[1] + p[1], center[2] + p[2]) for p in points]
    faces = []
    for s in range(segments):
        faces.append((0, 1 + (s + 1) % segments, 1 + s))
    for r in range(rings - 2):
        for s in range(segments):
            a = 1 + r * segments + s
            b = 1 + r * segments + (s + 1) % segments
            faces.append((a, b, b + segments, a + segments))
    last = len(points) - 1
    base = 1 + (rings - 2) * segments
    for s in range(segments):
        faces.append((last, base + s, base + (s + 1) % segments))
    add_faces(piece, points, faces)


def prism(piece, outline, normal, thickness):
    """Extrude a planar polygon (Roblox points, convex or simple) symmetrically along `normal`."""
    n = Vector(normal).normalized() * (thickness / 2)
    count = len(outline)
    points = [(p[0] - n.x, p[1] - n.y, p[2] - n.z) for p in outline]
    points += [(p[0] + n.x, p[1] + n.y, p[2] + n.z) for p in outline]
    faces = [tuple(range(count)), tuple(range(2 * count - 1, count - 1, -1))]
    for i in range(count):
        j = (i + 1) % count
        faces.append((i, count + i, count + j, j))
    add_faces(piece, points, faces)


def extrude_outline(piece, outline_xz, y0, y1):
    """Extrude a 2-D outline [(x, z)] on the ground plane from height y0 to y1 (stripes, lines)."""
    if len(outline_xz) < 3:
        return
    mid = (y0 + y1) / 2
    prism(piece, [(x, mid, z) for x, z in outline_xz], (0, 1, 0), y1 - y0)


def revolve(piece, profile, center=(0, 0, 0), segments=24, closed=False, rot=None):
    """
    Surface of revolution about the local Y axis. profile: [(radius, y)]; radius 0 = pole.
    Profiles that start and end on the axis are closed solids; closed=True joins the last ring
    back to the first (bands that never touch the axis). `rot` re-orients the local axis
    (e.g. rot_x(90) lays a wheel on its side).
    """
    points = []
    ring_index = []
    for r, y in profile:
        if r < 1e-6:
            ring_index.append(("pole", len(points)))
            points.append((0.0, y, 0.0))
        else:
            ring_index.append(("ring", len(points)))
            for s in range(segments):
                t = 2 * math.pi * s / segments
                points.append((r * math.cos(t), y, r * math.sin(t)))
    if rot is not None:
        points = [tuple(rot @ Vector(p)) for p in points]
    points = [(center[0] + p[0], center[1] + p[1], center[2] + p[2]) for p in points]
    faces = []
    pairs = list(zip(ring_index, ring_index[1:]))
    if closed:
        pairs.append((ring_index[-1], ring_index[0]))
    for (kind_a, a), (kind_b, b) in pairs:
        for s in range(segments):
            n = (s + 1) % segments
            if kind_a == "pole" and kind_b == "ring":
                faces.append((a, b + n, b + s))
            elif kind_a == "ring" and kind_b == "pole":
                faces.append((a + s, a + n, b))
            elif kind_a == "ring" and kind_b == "ring":
                faces.append((a + s, a + n, b + n, b + s))
    add_faces(piece, points, faces)


def ring_tube(piece, center, radius, width, depth, segments=24, axis="Y"):
    """Square-section ring. axis="Y": lies flat (ring in XZ plane); axis="Z": stands up (XY plane)."""
    points = []
    corners = [(-width / 2, -depth / 2), (width / 2, -depth / 2), (width / 2, depth / 2), (-width / 2, depth / 2)]
    for s in range(segments):
        t = 2 * math.pi * s / segments
        for dr, dz in corners:
            r = radius + dr
            if axis == "Z":
                points.append((center[0] + r * math.cos(t), center[1] + r * math.sin(t), center[2] + dz))
            else:
                points.append((center[0] + r * math.cos(t), center[1] + dz, center[2] + r * math.sin(t)))
    faces = []
    for s in range(segments):
        a = s * 4
        b = ((s + 1) % segments) * 4
        for k in range(4):
            k2 = (k + 1) % 4
            faces.append((a + k, a + k2, b + k2, b + k))
    add_faces(piece, points, faces)


def loft(piece, sections, cap_start=True, cap_end=True):
    """Closed-profile loft through equal-length point lists (Roblox space)."""
    count = len(sections[0])
    points = [p for section in sections for p in section]
    faces = []
    for i in range(len(sections) - 1):
        a = i * count
        b = (i + 1) * count
        for k in range(count):
            k2 = (k + 1) % count
            faces.append((a + k, a + k2, b + k2, b + k))
    if cap_start:
        faces.append(tuple(range(count - 1, -1, -1)))
    if cap_end:
        last = (len(sections) - 1) * count
        faces.append(tuple(range(last, last + count)))
    return add_faces(piece, points, faces)


def clip_convex(polygon, clip):
    """
    Sutherland-Hodgman: clip a 2-D polygon [(x, y)] by a CONVEX counter-clockwise polygon `clip`.
    Returns the clipped outline (possibly empty). Used to cut diagonal hazard stripes to a tile.

    Example: clip_convex([(0,0),(4,0),(4,4),(0,4)], [(1,1),(3,1),(3,3),(1,3)]) -> the inner square
    """

    def inside(p, a, b):
        return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]) >= -1e-9

    def intersect(p, q, a, b):
        x1, y1, x2, y2 = p[0], p[1], q[0], q[1]
        x3, y3, x4, y4 = a[0], a[1], b[0], b[1]
        den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if abs(den) < 1e-12:
            return q
        t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))

    output = list(polygon)
    for i in range(len(clip)):
        a, b = clip[i], clip[(i + 1) % len(clip)]
        source, output = output, []
        if not source:
            break
        for j in range(len(source)):
            p, q = source[j], source[(j + 1) % len(source)]
            if inside(q, a, b):
                if not inside(p, a, b):
                    output.append(intersect(p, q, a, b))
                output.append(q)
            elif inside(p, a, b):
                output.append(intersect(p, q, a, b))
    # Drop near-duplicate points so degenerate slivers never become broken faces.
    cleaned = []
    for p in output:
        if not cleaned or abs(p[0] - cleaned[-1][0]) + abs(p[1] - cleaned[-1][1]) > 1e-6:
            cleaned.append(p)
    if len(cleaned) > 1 and abs(cleaned[0][0] - cleaned[-1][0]) + abs(cleaned[0][1] - cleaned[-1][1]) <= 1e-6:
        cleaned.pop()
    return cleaned if len(cleaned) >= 3 else []
