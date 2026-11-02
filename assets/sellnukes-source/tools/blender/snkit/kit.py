"""
snkit.kit — chunky, stud-friendly toy building blocks for SellNukes models.

Design rules these helpers bake in (so every builder gets the "cute LEGO toy" read for free):
    * Big flat faces with small chamfers (studs read best on flat faces; chamfers catch light).
    * Low segment counts (12-20 around) — chunky, cheap, and the stud texture hides facets.
    * Hazard stripes are GEOMETRY (separate yellow + black pieces), never a texture, so they keep
      the stud material and tint like everything else.

All coordinates are Roblox space (studs, +Y up, front = -Z). Each helper takes the piece(s) to
append into, so callers decide colour grouping (fewer pieces = fewer draw calls).

Example:
    yellow = m.piece("HazardYellow", HAZARD_YELLOW); black = m.piece("HazardBlack", HAZARD_BLACK)
    hazard_band(yellow, black, center=(0, 0.4, -2), size=(10, 0.8, 0.3))
    tyre_ring(m.piece("Tyre", TYRE), (0, 0, 0), 2.2, 3.4, 1.1)
"""

from __future__ import annotations

import math

from mathutils import Vector

from .shapes import add_faces, bar, box, clip_convex, cylinder, ellipsoid, extrude_outline, frame_from, prism, revolve


def block(piece, center, size, bevel=0.12, rot=None, segments=1):
    """Toy block: box with a chamfer clamped to 20 % of its smallest side (never self-intersects)."""
    limit = 0.2 * min(size)
    box(piece, center, size, rot=rot, bevel=min(bevel, limit), segments=segments)


def _stripe_polys(length, height, stripe, angle_deg):
    """
    Diagonal stripe parallelograms covering a [-length/2, length/2] x [-height/2, height/2] rect,
    clipped to it. Returns (even_polys, odd_polys) as 2-D outlines (u, v).
    """
    slope = math.tan(math.radians(angle_deg))
    shift = height / max(slope, 1e-6)  # horizontal run of one stripe edge across the height
    rect = [(-length / 2, -height / 2), (length / 2, -height / 2), (length / 2, height / 2), (-length / 2, height / 2)]
    even, odd = [], []
    start = -length / 2 - shift - stripe
    i = 0
    u = start
    while u < length / 2 + stripe:
        poly = [
            (u, -height / 2),
            (u + stripe, -height / 2),
            (u + stripe + shift, height / 2),
            (u + shift, height / 2),
        ]
        clipped = clip_convex(poly, rect)
        if clipped:
            (even if i % 2 == 0 else odd).append(clipped)
        u += stripe
        i += 1
    return even, odd


def hazard_band(yellow, black, center, size, stripe=0.9, angle=50.0, axis="x"):
    """
    Upright hazard band (door kick-plates, machine skirts). Stripes run diagonally across the
    band's long side; `axis` = which Roblox axis the band runs along ("x" or "z").
    size = (length, height, depth) in band space.
    """
    length, height, depth = size
    even, odd = _stripe_polys(length, height, stripe, angle)
    cx, cy, cz = center
    for polys, piece in ((even, yellow), (odd, black)):
        for poly in polys:
            if axis == "x":
                pts = [(cx + u, cy + v, cz) for u, v in poly]
                prism(piece, pts, (0, 0, 1), depth)
            else:
                pts = [(cx, cy + v, cz + u) for u, v in poly]
                prism(piece, pts, (1, 0, 0), depth)


def hazard_floor(yellow, black, center, size_xz, height, stripe=2.0, angle=45.0, inset=0.0):
    """
    Flat hazard-striped slab (ground tiles, pad aprons): stripes diagonal in the XZ plane.
    center = slab centre; size_xz = (sx, sz); height = slab thickness. `inset` shrinks the stripe
    area (leaves a border for a frame piece). Pass black=None to emit only the yellow stripes.
    """
    sx, sz = size_xz[0] - 2 * inset, size_xz[1] - 2 * inset
    even, odd = _stripe_polys(sx, sz, stripe, angle)
    cx, cy, cz = center
    for polys, piece in ((even, yellow), (odd, black)):
        if piece is None:
            continue  # e.g. yellow stripes raised over a black plate: skip the black stripes
        for poly in polys:
            extrude_outline(piece, [(cx + u, cz + v) for u, v in poly], cy - height / 2, cy + height / 2)


def hazard_ring(yellow, black, center, r_in, r_out, y0, y1, count=16, slices=2):
    """Flat ring of alternating yellow/black segments around a round base (reactors, silos)."""
    cx, _, cz = center
    for i in range(count):
        piece = yellow if i % 2 == 0 else black
        a0 = 2 * math.pi * i / count
        a1 = 2 * math.pi * (i + 1) / count
        angles = [a0 + (a1 - a0) * k / slices for k in range(slices + 1)]
        outer = [(cx + r_out * math.cos(a), cz + r_out * math.sin(a)) for a in angles]
        inner = [(cx + r_in * math.cos(a), cz + r_in * math.sin(a)) for a in reversed(angles)]
        extrude_outline(piece, outer + inner, y0, y1)


def pipe(piece, points, radius, segments=10, joints=True):
    """Pipe along a polyline: one cylinder per leg, a chunky collar at every bend."""
    for a, b in zip(points, points[1:]):
        cylinder(piece, a, b, radius, segments=segments)
    if joints:
        for p in points[1:-1]:
            ellipsoid(piece, p, (radius * 1.35, radius * 1.35, radius * 1.35), rings=5, segments=segments)


def tank(body, bands, center, radius, height, segments=18, band_count=2):
    """Upright tank: cylinder with rounded caps (revolve) + raised band rings (separate piece)."""
    cx, cy, cz = center
    cap = min(radius * 0.45, height * 0.25)
    profile = [
        (0.0, 0.0),
        (radius * 0.8, 0.0),
        (radius, cap * 0.5),
        (radius, height - cap * 0.5),
        (radius * 0.8, height),
        (radius * 0.35, height + cap * 0.35),
        (0.0, height + cap * 0.4),
    ]
    revolve(body, profile, center=(cx, cy, cz), segments=segments)
    for k in range(band_count):
        y = cy + height * (k + 1) / (band_count + 1)
        # Closed square-section ring hugging the wall (inner lip hidden inside the body).
        revolve(
            bands,
            [(radius * 0.98, -0.18), (radius * 1.06, -0.18), (radius * 1.06, 0.18), (radius * 0.98, 0.18)],
            center=(cx, y, cz),
            segments=segments,
            closed=True,
        )


def truss(piece, a, b, width, member=0.22, bays=4):
    """
    Square lattice column (gantry / crane mast) from a to b: four corner bars, horizontal rings
    and one diagonal per face per bay. Axis must be mostly vertical.
    """
    a, b = Vector(a), Vector(b)
    h = width / 2
    corners = [(-h, -h), (h, -h), (h, h), (-h, h)]
    for dx, dz in corners:
        bar(piece, (a.x + dx, a.y, a.z + dz), (b.x + dx, b.y, b.z + dz), member)
    for i in range(bays + 1):
        t = i / bays
        p = a.lerp(b, t)
        for k in range(4):
            c0, c1 = corners[k], corners[(k + 1) % 4]
            bar(piece, (p.x + c0[0], p.y, p.z + c0[1]), (p.x + c1[0], p.y, p.z + c1[1]), member * 0.8)
        if i < bays:
            q = a.lerp(b, (i + 1) / bays)
            for k in range(4):
                c0, c1 = corners[k], corners[(k + 1) % 4]
                bar(piece, (p.x + c0[0], p.y, p.z + c0[1]), (q.x + c1[0], q.y, q.z + c1[1]), member * 0.7)


def ladder(piece, base, height, width=1.6, rung_step=0.9, rail=0.18, facing="z"):
    """Two rails + rungs. `base` = centre of the foot; ladder plane faces -Z ("z") or -X ("x")."""
    bx, by, bz = base
    off = (width / 2, 0) if facing == "z" else (0, width / 2)
    for s in (-1, 1):
        x, z = bx + s * off[0], bz + s * off[1]
        bar(piece, (x, by, z), (x, by + height, z), rail)
    y = by + rung_step * 0.6
    while y < by + height - 0.2:
        bar(piece, (bx - off[0], y, bz - off[1]), (bx + off[0], y, bz + off[1]), rail * 0.8)
        y += rung_step


def sign_frame(frame, panel, center, size, border=0.3, depth=0.4, posts=0.0, post_piece=None):
    """
    Framed sign board facing -Z. size = (width, height). posts > 0 adds two legs down to y = 0
    of that thickness (into post_piece or the frame piece). The text/decal goes on the panel.
    """
    cx, cy, cz = center
    w, h = size
    block(panel, (cx, cy, cz), (w - border, h - border, depth * 0.7), bevel=0.05)
    t = border
    block(frame, (cx, cy + h / 2 - t / 2, cz), (w, t, depth), bevel=0.06)
    block(frame, (cx, cy - h / 2 + t / 2, cz), (w, t, depth), bevel=0.06)
    block(frame, (cx - w / 2 + t / 2, cy, cz), (t, h, depth), bevel=0.06)
    block(frame, (cx + w / 2 - t / 2, cy, cz), (t, h, depth), bevel=0.06)
    if posts > 0:
        target = post_piece or frame
        bottom = cy - h / 2
        for s in (-1, 1):
            block(target, (cx + s * (w / 2 - posts), bottom / 2, cz + depth), (posts, bottom, posts), bevel=0.05)


def tyre_ring(piece, center, r_in, r_out, height, lugs=16, segments=32):
    """
    Chunky tyre lying flat (buy pads): rounded-shoulder ring (revolve) + raised tread lugs on its
    outer wall, like the reference pads. Pivot: centre of the bottom.
    """
    cx, cy, cz = center
    shoulder = min(0.25, height * 0.25)
    profile = [
        (r_in, 0.0),
        (r_out - shoulder, 0.0),
        (r_out, shoulder),
        (r_out, height - shoulder),
        (r_out - shoulder, height),
        (r_in, height),
    ]
    revolve(piece, profile, center=(cx, cy, cz), segments=segments, closed=True)
    lug_w = 2 * math.pi * r_out / lugs * 0.5
    for i in range(lugs):
        a = 2 * math.pi * (i + 0.5) / lugs
        dirx, dirz = math.cos(a), math.sin(a)
        c = (cx + dirx * (r_out + 0.08), cy + height / 2, cz + dirz * (r_out + 0.08))
        # Rotation whose local X is tangent, local Z is radial.
        tangent = (-dirz, 0, dirx)
        rot = frame_from(tangent, (0, 1, 0))
        box(piece, c, (lug_w, height * 0.62, 0.28), rot=rot, bevel=0.05)


def nuke_body(body, nose, fins, core, base=(0, 0, 0), length=3.0, radius=0.7, fin_count=4, segments=16):
    """
    Cartoon nuke standing on its fins, nose up (+Y). Chubby capsule body, rounded nose cone,
    `fin_count` chunky fins, and a glowing core band (Neon piece) around the middle.
    base = centre of the fin bottoms. Returns the y of the core band centre (for decals/badges).
    """
    bx, by, bz = base
    fin_h = length * 0.28
    body_y0 = by + fin_h * 0.35
    body_len = length * 0.62
    nose_len = length - (body_y0 - by) - body_len
    r = radius
    body_profile = [
        (0.0, 0.0),
        (r * 0.7, 0.0),
        (r * 0.95, body_len * 0.06),
        (r, body_len * 0.18),
        (r, body_len),
        (0.0, body_len),
    ]
    revolve(body, body_profile, center=(bx, body_y0, bz), segments=segments)
    nose_profile = [
        (0.0, 0.0),
        (r * 1.02, 0.0),
        (r * 0.95, nose_len * 0.35),
        (r * 0.7, nose_len * 0.7),
        (r * 0.35, nose_len * 0.93),
        (0.0, nose_len),
    ]
    revolve(nose, nose_profile, center=(bx, body_y0 + body_len, bz), segments=segments)
    # Core band: slightly proud glowing ring at ~45 % height.
    core_y = body_y0 + body_len * 0.45
    revolve(
        core,
        [(r * 0.96, -0.16 * length / 3), (r * 1.06, -0.12 * length / 3), (r * 1.06, 0.12 * length / 3), (r * 0.96, 0.16 * length / 3)],
        center=(bx, core_y, bz),
        segments=segments,
        closed=True,
    )
    # Flared nozzle foot under the body (in the fin piece): the nuke stands on it, so a fin seen
    # edge-on never reads as a lone "stalk".
    revolve(
        fins,
        [(0.0, by), (r * 0.62, by), (r * 0.5, body_y0 * 0.5 + by * 0.5), (r * 0.55, body_y0 + 0.04), (0.0, body_y0 + 0.04)],
        center=(bx, 0, bz),
        segments=segments,
    )
    # Fins: chunky trapezoids, extruded tangentially.
    for i in range(fin_count):
        a = 2 * math.pi * i / fin_count + math.pi / 4
        dx, dz = math.cos(a), math.sin(a)
        r0 = r * 0.6
        r1 = r * 1.7
        outline = [
            (bx + dx * r0, by, bz + dz * r0),
            (bx + dx * r1, by, bz + dz * r1),
            (bx + dx * r1 * 0.92, by + fin_h * 0.55, bz + dz * r1 * 0.92),
            (bx + dx * r0, by + fin_h * 1.25, bz + dz * r0),
        ]
        prism(fins, outline, (-dz, 0, dx), max(0.24, r * 0.4))
    return core_y


def tree(trunk, leaves, base, height=6.0, crown=2.6):
    """Chunky toy tree: square trunk + three stacked, shrinking beveled leaf blocks."""
    bx, by, bz = base
    trunk_h = height * 0.4
    block(trunk, (bx, by + trunk_h / 2, bz), (0.9, trunk_h, 0.9), bevel=0.12)
    y = by + trunk_h
    size = crown
    for k in range(3):
        h = size * 0.75
        block(leaves, (bx, y + h / 2, bz), (size, h, size), bevel=0.3, segments=2)
        y += h * 0.8
        size *= 0.72


def lamp(post, cage, bulb, base, height=5.0, bulb_radius=0.5, segments=12):
    """Toy lamp post: chamfered foot, round pole, square cage, glowing bulb (Neon piece)."""
    bx, by, bz = base
    block(post, (bx, by + 0.2, bz), (1.4, 0.4, 1.4), bevel=0.1)
    cylinder(post, (bx, by + 0.4, bz), (bx, by + height - 0.6, bz), 0.16, segments=segments)
    top = by + height - 0.6
    block(cage, (bx, top + 0.05, bz), (1.3, 0.2, 1.3), bevel=0.05)
    block(cage, (bx, top + 1.35, bz), (1.3, 0.25, 1.3), bevel=0.05)
    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(cage, (bx + sx * 0.55, top + 0.1, bz + sz * 0.55), (bx + sx * 0.55, top + 1.25, bz + sz * 0.55), 0.12)
    ellipsoid(bulb, (bx, top + 0.7, bz), (bulb_radius, bulb_radius * 1.15, bulb_radius), rings=6, segments=segments)


def disc(piece, center, radius, height, segments=24, bevel=0.12):
    """Flat rounded-edge disc (pad tops, can lids, dials). Pivot = bottom centre."""
    cx, cy, cz = center
    b = min(bevel, height * 0.45, radius * 0.3)
    revolve(
        piece,
        [(0.0, 0.0), (radius - b, 0.0), (radius, b), (radius, height - b), (radius - b, height), (0.0, height)],
        center=(cx, cy, cz),
        segments=segments,
    )


def trefoil(piece, center, radius, depth, normal=(0, 0, -1), up=(0, 1, 0), hub=0.18, segments=6):
    """
    Cartoon radiation trefoil (three blades + hub) as a thin prism facing `normal`. Placed on a
    contrasting disc (badge). radius = blade outer radius.
    """
    n = Vector(normal).normalized()
    u = Vector(up).normalized()
    side = u.cross(n).normalized()
    c = Vector(center)

    def to3(px, py):
        p = c + side * px + u * py
        return (p.x, p.y, p.z)

    r0 = radius * 0.32
    for k in range(3):
        mid = math.radians(90 + 120 * k)
        half = math.radians(30)
        arc = [mid - half + (2 * half) * s / segments for s in range(segments + 1)]
        outline = [to3(radius * math.cos(a), radius * math.sin(a)) for a in arc]
        outline += [to3(r0 * math.cos(a), r0 * math.sin(a)) for a in reversed(arc)]
        prism(piece, outline, n, depth)
    hub_pts = [to3(radius * hub * math.cos(2 * math.pi * s / 12), radius * hub * math.sin(2 * math.pi * s / 12)) for s in range(12)]
    prism(piece, hub_pts, n, depth)


__all__ = [
    "add_faces",
    "block",
    "disc",
    "hazard_band",
    "hazard_floor",
    "hazard_ring",
    "ladder",
    "lamp",
    "nuke_body",
    "pipe",
    "sign_frame",
    "tank",
    "tree",
    "trefoil",
    "truss",
    "tyre_ring",
]
