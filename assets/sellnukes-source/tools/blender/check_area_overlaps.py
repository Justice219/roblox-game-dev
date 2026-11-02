"""
check_area_overlaps.py — interpenetration self-check for area layouts (owner R24: "a hedge goes
through the garage"). Run headless in Blender; exits 1 when two visible pieces from DIFFERENT
models in an area intersect by more than TOLERANCE studs on all three axes, unless the pair is an
intended overlap listed in ALLOWED (with its reason).

How it works:
    1. lune dumps every model placement of the real layout modules (base + every build group) via
       tools/blender/dump_area_layouts.luau (slot-local CFrames).
    2. Each model is rebuilt from its Blender builder (same code as generate_world.py) and every
       piece is split into connected mesh ISLANDS (a hedge row, a tree trunk, one letter block),
       each with its own model-space bounding box. Island boxes are far tighter than whole-piece
       boxes (one "Leaves" piece spans every tree on a lot).
    3. Island boxes are placed with the layout CFrames (rotated boxes are re-boxed) and tested
       pairwise across different placements; touching / resting contact (<= TOLERANCE on any axis)
       is fine.
    4. Every box hit is CONFIRMED on the real triangles (A1-art, 2026-10-30). A box only says "the
       hulls overlap": a prop standing inside a hollow shell (lab walls, a cave back with its
       floor gems) overlaps the shell's island box without touching a wall. A pair is reported
       only when its surfaces really interpenetrate by more than TOLERANCE:
         the depth is the thinnest axis of the box of the SOLID intersection A n B (the same
         measure as the island-box test, on exact geometry). Its corners are A's vertices inside
         B, B's vertices inside A (BVH nearest point + outward normal) and the points where an
         edge of one crosses a face of the other (BVHTree.overlap lists the crossing triangles).
         A hedge through a wall: hedge cross-section x wall thickness. A prop inside a hollow
         shell: no corners, 0. The printed depth is this confirmed depth, not the box depth.

Usage (repo root):
    /opt/homebrew/bin/blender -b --python tools/blender/check_area_overlaps.py -- 1 2 3
    /opt/homebrew/bin/blender -b --python tools/blender/check_area_overlaps.py -- --world dino 1 2 3 4 5 6
    (add --verbose to list allowed overlaps too)

Worlds (owner R57, W7 2026-10-31): `--world <id>` checks that world's layouts (the dump reads
WorldsConfig.get(id).layoutFolder). ALLOWED rows are keyed by (world, area); without the flag the
world is "main" and everything behaves exactly as before.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import bmesh  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

import generate_world  # noqa: E402
from snkit.core import br  # noqa: E402
from snkit import export as snexport  # noqa: E402

TOLERANCE = 0.2  # studs of overlap allowed on at least one axis (resting contact, bevel slop)

# Intended interpenetrations per world: (area, keyA, pieceA or "*", keyB, pieceB or "*", reason).
# Order-free. Main-world rows live in ALLOWED; other worlds add a list under their id below.
ALLOWED = [
    (1, "Garage_*", "*", "Garage_*", "*", "B4's garage shell: walls, roof and door interlock by design"),
    (1, "A1_ReactorPack", "Pipes", "Garage_WallSide", "*", "coolant pipes run into the garage wall"),
    (5, "A5_CentrifugeRotor", "Rotor", "A5_CentrifugeRow", "Glass", "each rotor spins INSIDE its drum's glass dome (a solid glass piece; R41)"),
    (10, "A10_CoolingTower*", "Pipes", "A10_ReactorDome", "Drum", "the cooling towers' coolant pipes plug into the reactor drum"),
]


def _match(pattern: str, value: str) -> bool:
    """Tiny glob: exact match, "*" or a trailing-* prefix."""
    if pattern == "*":
        return True
    if pattern.endswith("*"):
        return value.startswith(pattern[:-1])
    return pattern == value


ALLOWED_BY_WORLD = {
    "main": ALLOWED,
    "dino": [],  # Dino Valley D1-D6: no intended interpenetrations (W6 / W7 / W8)
}


def allowed(area, a, b, world="main"):
    """Reason string if the island pair (a, b) = ((key, piece), (key, piece)) is an intended overlap."""
    for rule_area, ka, pa, kb, pb, reason in ALLOWED_BY_WORLD.get(world, []):
        if rule_area != area:
            continue
        for x, y in ((a, b), (b, a)):
            if _match(ka, x[0]) and _match(pa, x[1]) and _match(kb, y[0]) and _match(pb, y[1]):
                return reason
    return None


def islands(piece_bm):
    """
    Connected components of a bmesh, each as (lo, hi, verts, tris) in ROBLOX space (model-local):
    lo / hi = its bounding box, verts = [(x, y, z)], tris = [(i, j, k)] indices into verts. The
    triangles are kept so box hits can be confirmed on the real surface (see the module header).
    """
    piece_bm.verts.ensure_lookup_table()
    # Island id per vertex (flood fill over edges).
    owner = {}
    groups = []
    for start in piece_bm.verts:
        if start.index in owner:
            continue
        gid = len(groups)
        members = [start.index]
        owner[start.index] = gid
        stack = [start]
        while stack:
            v = stack.pop()
            for e in v.link_edges:
                w = e.other_vert(v)
                if w.index not in owner:
                    owner[w.index] = gid
                    members.append(w.index)
                    stack.append(w)
        groups.append(members)
    # Triangles per island (a face's corners all share one island).
    tris_by_group = [[] for _ in groups]
    for loops in piece_bm.calc_loop_triangles():
        corners = tuple(loop.vert.index for loop in loops)
        tris_by_group[owner[corners[0]]].append(corners)
    result = []
    for gid, members in enumerate(groups):
        local = {index: n for n, index in enumerate(members)}
        verts = [br(piece_bm.verts[index].co) for index in members]
        lo = [min(v[i] for v in verts) for i in range(3)]
        hi = [max(v[i] for v in verts) for i in range(3)]
        tris = [(local[a], local[b], local[c]) for (a, b, c) in tris_by_group[gid]]
        result.append((lo, hi, verts, tris))
    return result


def model_islands(key, builder):
    """{pieceName: [(lo, hi)]} for one model, built exactly like generate_world.py builds it."""
    snexport.reset_scene()
    model = builder()
    out = {}
    for name, piece in model.pieces.items():
        bm = piece.bm
        if len(bm.verts) == 0:
            continue
        bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
        # Same clean-up as snkit.export.realize: outward normals, which the inside test relies on
        # (builders don't guarantee winding, e.g. a revolve's profile direction).
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
        out[name] = islands(bm)
    return out


def place(box, comps):
    """Transform a model-space box by CFrame components (x, y, z, R00..R22) -> slot-space box."""
    (lo, hi) = box
    pos = Vector(comps[0:3])
    rot = Matrix((comps[3:6], comps[6:9], comps[9:12]))
    centre = Vector([(lo[i] + hi[i]) / 2 for i in range(3)])
    half = Vector([(hi[i] - lo[i]) / 2 for i in range(3)])
    c = rot @ centre + pos
    h = Vector([sum(abs(rot[r][k]) * half[k] for k in range(3)) for r in range(3)])
    return (c - h, c + h)


def place_points(verts, comps):
    """Transform model-space points by CFrame components -> slot-space Vectors."""
    pos = Vector(comps[0:3])
    rot = Matrix((comps[3:6], comps[6:9], comps[9:12]))
    return [rot @ Vector(v) + pos for v in verts]


def box_depth(lo_a, hi_a, lo_b, hi_b):
    """Overlap of two boxes on their thinnest shared axis (<= 0 when they are apart)."""
    return min(min(hi_a[k], hi_b[k]) - max(lo_a[k], lo_b[k]) for k in range(3))


def inside_points(points, lo, hi, bvh):
    """
    The `points` that lie strictly INSIDE the closed surface `bvh` (box lo / hi): the nearest
    surface point's outward normal points away from an inside point. Points on the surface (resting
    contact) are not inside.
    """
    found = []
    for p in points:
        if not all(lo[k] < p[k] < hi[k] for k in range(3)):
            continue
        location, normal, _, distance = bvh.find_nearest(p)
        if location is not None and distance > 1e-4 and (p - location).dot(normal) < 0:
            found.append(p)
    return found


def segment_tri(p, q, a, b, c):
    """Point where segment p-q crosses triangle abc, or None (parallel / misses / only touches)."""
    n = (b - a).cross(c - a)
    dp, dq = n.dot(p - a), n.dot(q - a)
    if dp * dq >= 0 or dp == dq:
        return None
    x = p + (q - p) * (dp / (dp - dq))
    # Barycentric inside test (edges included).
    for u, v in ((a, b), (b, c), (c, a)):
        if n.dot((v - u).cross(x - u)) < -1e-9 * n.length_squared:
            return None
    return x


def confirmed_depth(a, b):
    """
    Real interpenetration depth of two placed islands (studs): the thinnest axis of the bounding
    box of the solid intersection A n B. For polyhedra that box is spanned exactly by the
    vertices of A n B: A's vertices inside B, B's vertices inside A, and the points where an edge
    of one crosses a face of the other (only triangle pairs that BVHTree.overlap reports can
    cross). 0 = the surfaces only share a hull (a prop inside a hollow shell) or merely touch.
    """
    corners = inside_points(a["points"], b["lo"], b["hi"], b["bvh"])
    corners += inside_points(b["points"], a["lo"], a["hi"], a["bvh"])
    for i, j in a["bvh"].overlap(b["bvh"]):
        ta = [a["points"][v] for v in a["tris"][i]]
        tb = [b["points"][v] for v in b["tris"][j]]
        for edge_of, face in ((ta, tb), (tb, ta)):
            for k in range(3):
                x = segment_tri(edge_of[k], edge_of[(k + 1) % 3], *face)
                if x is not None:
                    corners.append(x)
    if len(corners) < 2:
        return 0.0
    return min(max(c[k] for c in corners) - min(c[k] for c in corners) for k in range(3))


def main() -> int:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    verbose = "--verbose" in argv
    world = "main"
    if "--world" in argv:
        at = argv.index("--world")
        if at + 1 >= len(argv) or argv[at + 1].startswith("--"):
            raise SystemExit("usage: --world <id>")
        world = argv[at + 1]
    areas = [int(a) for a in argv if a.isdigit()]
    if not areas:
        raise SystemExit("usage: blender -b --python check_area_overlaps.py -- [--world <id>] <area> [area ...] [--verbose]")
    world_args = [] if world == "main" else ["--world", world]
    label = "" if world == "main" else f"{world} "
    lune = os.path.expanduser("~/.aftman/bin/lune")
    with tempfile.TemporaryDirectory(prefix="sn-overlaps-") as tmp:
        dump = os.path.join(tmp, "layouts.json")
        subprocess.run([lune, "run", "tools/blender/dump_area_layouts.luau", dump, *world_args, *map(str, areas)], cwd=ROOT, check=True, timeout=120)
        with open(dump) as handle:
            layouts = json.load(handle)
    keys = sorted({p["key"] for placements in layouts.values() for p in placements})
    builders = generate_world.collect_builders(keys)
    cache = {key: model_islands(key, builders[key]) for key in keys}
    failures = 0
    for area_text, placements in sorted(layouts.items(), key=lambda kv: int(kv[0])):
        area = int(area_text)
        # Every island of every placement, tagged with its placement id.
        items = []
        for pid, placement in enumerate(placements):
            for piece, parts in cache[placement["key"]].items():
                for n, (ilo, ihi, verts, tris) in enumerate(parts):
                    lo, hi = place((ilo, ihi), placement["cf"])
                    island = {"verts": verts, "tris": tris, "cf": placement["cf"], "id": (pid, piece, n)}
                    items.append((lo.x, hi.x, lo, hi, pid, placement["key"], piece, placement["group"], island))
        # Slot-space points + BVH per island, built lazily (only islands in a box hit need them).
        surfaces = {}

        def surface(island):
            cached = surfaces.get(island["id"])
            if cached is None:
                points = place_points(island["verts"], island["cf"])
                cached = {
                    "points": points,
                    "tris": island["tris"],
                    "bvh": BVHTree.FromPolygons(points, island["tris"], all_triangles=True, epsilon=0.0),
                    "lo": [min(p[k] for p in points) for k in range(3)],
                    "hi": [max(p[k] for p in points) for k in range(3)],
                }
                surfaces[island["id"]] = cached
            return cached

        items.sort(key=lambda it: it[0])
        problems, ok_overlaps = {}, {}
        for i, a in enumerate(items):
            for b in items[i + 1 :]:
                if b[0] >= a[1] - TOLERANCE:
                    break  # sorted by min x: no later island can overlap a on X
                if a[4] == b[4]:
                    continue  # same placed model: intra-model geometry is the builder's business
                depth = [min(a[3][k], b[3][k]) - max(a[2][k], b[2][k]) for k in range(3)]
                if min(depth) <= TOLERANCE:
                    continue
                pair = tuple(sorted(((a[5], a[6], a[7]), (b[5], b[6], b[7]))))
                reason = allowed(area, (a[5], a[6]), (b[5], b[6]), world)
                target = ok_overlaps if reason else problems
                worst = target.get(pair, (0.0, None, reason))
                # Confirm on the real triangles (hulls overlapping is not interpenetration).
                real = confirmed_depth(surface(a[8]), surface(b[8]))
                if real <= TOLERANCE:
                    continue
                if real > worst[0]:
                    sa, sb = surface(a[8]), surface(b[8])
                    lo = [max(sa["lo"][k], sb["lo"][k]) for k in range(3)]
                    hi = [min(sa["hi"][k], sb["hi"][k]) for k in range(3)]
                    at = tuple(round((lo[k] + hi[k]) / 2, 1) for k in range(3))
                    target[pair] = (real, at, reason)
        print(f"[overlaps] {label}Area{area:02d}: {len(placements)} placements, {len(items)} islands, "
              f"{len(problems)} problem pair(s), {len(ok_overlaps)} allowed")
        for (ma, mb), (d, at, _) in sorted(problems.items()):
            print(f"  PROBLEM {ma[0]}.{ma[1]} [{ma[2]}] x {mb[0]}.{mb[1]} [{mb[2]}]: {d:.2f} studs deep near {at}")
        if verbose:
            for (ma, mb), (d, at, reason) in sorted(ok_overlaps.items()):
                print(f"  allowed {ma[0]}.{ma[1]} x {mb[0]}.{mb[1]}: {d:.2f} ({reason})")
        failures += len(problems)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
