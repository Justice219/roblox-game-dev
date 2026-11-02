"""
_npc_rig — turns a manager NPC figure into ANIMATABLE rig pieces (owner R30: "the little NPCs that
you hire ... actually move around and be animated and not just a still prop").

Why:
    A MeshPart has one colour, so builders group geometry by colour ("Coat" = torso + both sleeves,
    "Skin" = head + hands). A limb cannot swing if it is welded into the torso's mesh. This helper
    re-partitions the finished model by BODY PART without touching the builders' geometry calls:
    every connected island of every piece is assigned to the nearest bone of a simple skeleton,
    and each (bone, colour) pair becomes its own piece named `<Group><Piece>`:

        Coat  ->  TorsoCoat, ArmLCoat, ArmRCoat         Skin -> HeadSkin, ArmLSkin, ArmRSkin
        Shoes ->  LegLShoes, LegRShoes                   Hair -> HeadHair

    Rig groups (the client's `Tycoon/Npc/ManagerController` matches the leading word):
        Torso  root of the upper body (pivot = hip centre)    Head  pivot = neck
        ArmL / ArmR  pivot = shoulder (L = the figure's own left = local -X)
        LegL / LegR  pivot = hip socket
    Islands far from every bone (desks, podiums, consoles sharing a colour) keep the ORIGINAL piece
    name and stay static props. `static` pieces are never split; `assign` forces whole pieces into
    one group (a clipboard held in front of the chest -> "ArmR").

Joints:
    `rig_split` returns the joint positions (model space, Roblox axes) and prints a ready-to-paste
    `ManagerNpcConfig.Rigs` row so the Luau config always matches the meshes.

Not a model module (leading underscore: generate_world.py does not auto-discover it).

Example (end of a manager builder):
    a = toy_figure({...}, left_arm=(12, 0), right_arm=(10, 55))
    rig_split(m, a1_bones(a))
    return m
"""

from __future__ import annotations

import math

import bmesh
from mathutils import Vector

from snkit.core import Piece

GROUPS = ("Torso", "Head", "ArmL", "ArmR", "LegL", "LegR")

# Bone thickness: an island is scored by (distance to the bone segment - radius), so a chunky
# torso claims its own surface details (tie, badge) before a nearby thin arm does.
RADIUS = {"Torso": 1.0, "Head": 0.85, "ArmL": 0.4, "ArmR": 0.4, "LegL": 0.45, "LegR": 0.45}


def _seg_dist(p: Vector, a: Vector, b: Vector) -> float:
    """Distance from point p to the segment a-b (all Roblox-space Vectors)."""
    ab = b - a
    length2 = ab.length_squared
    if length2 < 1e-12:
        return (p - a).length
    t = max(0.0, min(1.0, (p - a).dot(ab) / length2))
    return (p - (a + ab * t)).length


def _islands(bm) -> list:
    """Connected face islands of a bmesh (union-find over edges). Returns lists of face indices."""
    bm.verts.ensure_lookup_table()
    bm.verts.index_update()
    bm.faces.ensure_lookup_table()
    bm.faces.index_update()
    parent = list(range(len(bm.verts)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for edge in bm.edges:
        a, b = find(edge.verts[0].index), find(edge.verts[1].index)
        if a != b:
            parent[a] = b
    groups: dict = {}
    for face in bm.faces:
        groups.setdefault(find(face.verts[0].index), []).append(face.index)
    return list(groups.values())


def _island_centre(bm, faces) -> Vector:
    """Bounding-box centre of an island, converted to Roblox axes (Blender (x, y, z) -> (x, z, -y))."""
    lo = Vector((math.inf, math.inf, math.inf))
    hi = Vector((-math.inf, -math.inf, -math.inf))
    for fi in faces:
        for v in bm.faces[fi].verts:
            for k in range(3):
                lo[k] = min(lo[k], v.co[k])
                hi[k] = max(hi[k], v.co[k])
    c = (lo + hi) * 0.5
    return Vector((c.x, c.z, -c.y))


def _subset(bm, keep: set):
    """Copy of `bm` holding only the faces whose index is in `keep` (loose geometry removed)."""
    out = bm.copy()
    out.faces.ensure_lookup_table()
    drop = [out.faces[i] for i in range(len(out.faces)) if i not in keep]
    if drop:
        bmesh.ops.delete(out, geom=drop, context="FACES")
    return out


def rig_split(m, bones: dict, *, static=(), assign=None, reach: float = 1.6, frame=((0.0, 0.0, 0.0), 0.0)):
    """
    Re-partition model `m` into rig pieces (see module doc). Mutates m.pieces in place.

    m:      snkit Model (after every geometry call of the builder)
    bones:  {group: (a, b)} Roblox-space segments; a = the joint (pivot) end. Missing groups are
            fine (a hover robot has no legs).
    static: piece names never split (furniture that only shares the model)
    assign: {piece name: group} — the whole piece joins that group (held props)
    reach:  islands whose best score (distance - bone radius) exceeds this stay static props
    frame:  (base, yaw degrees) of the figure inside the model, printed for the Luau config
    Returns {group: joint (x, y, z)} in model space.
    """
    assign = assign or {}
    segs = {g: (Vector(a), Vector(b)) for g, (a, b) in bones.items() if g in GROUPS}
    new_pieces: dict = {}
    for name, piece in list(m.pieces.items()):
        if name in static or len(piece.bm.faces) == 0:
            new_pieces[name] = piece
            continue
        buckets: dict = {}
        if name in assign:
            buckets[assign[name]] = set(range(len(piece.bm.faces)))
        else:
            for faces in _islands(piece.bm):
                c = _island_centre(piece.bm, faces)
                best, best_score = None, math.inf
                for g, (a, b) in segs.items():
                    score = _seg_dist(c, a, b) - RADIUS[g]
                    if score < best_score:
                        best, best_score = g, score
                key = best if (best is not None and best_score <= reach) else None
                buckets.setdefault(key, set()).update(faces)
        for group, keep in buckets.items():
            out_name = name if group is None else f"{group}{name}"
            if out_name in new_pieces:
                raise ValueError(f"{m.key}: rig piece name clash {out_name}")
            if len(buckets) == 1:
                bm = piece.bm
            else:
                bm = _subset(piece.bm, keep)
            split = Piece(out_name, piece.color, piece.material, piece.tinted, piece.transparency)
            split.bm.free()
            split.bm = bm
            new_pieces[out_name] = split
        if len(buckets) > 1:
            piece.bm.free()
    m.pieces = new_pieces
    joints = {g: tuple(round(x, 3) for x in bones[g][0]) for g in GROUPS if g in bones}
    base, yaw = frame
    print(f"[npc_rig] {m.key}: {len(m.pieces)} pieces; ManagerNpcConfig row:")
    print(f"\tfigure = {{ base = Vector3.new({base[0]}, {base[1]}, {base[2]}), yaw = {yaw} }},")
    print("\tjoints = {")
    for g, (x, y, z) in joints.items():
        print(f"\t\t{g} = Vector3.new({x}, {y}, {z}),")
    print("\t},")
    return joints


def a1_bones(anchors: dict) -> dict:
    """
    Skeleton of area01's `toy_figure` (figure at the model origin, facing -Z) from its anchors.
    Legs hang from (+-0.5, hip); shoulders at (+-1.42, shoulder_y); neck = head bottom.
    """
    hip = anchors["hip"]
    sy = anchors["shoulder_y"]
    hc = anchors["head"]
    hh = anchors["head_size"][1]
    neck = hc[1] - hh / 2 - 0.05
    hands = anchors["hands"]
    return {
        "Torso": ((0.0, hip, 0.0), (0.0, neck, 0.0)),
        "Head": ((0.0, neck, 0.0), (0.0, hc[1] + hh / 2, 0.0)),
        "ArmL": ((-1.42, sy, 0.0), tuple(hands["left"])),
        "ArmR": ((1.42, sy, 0.0), tuple(hands["right"])),
        "LegL": ((-0.5, hip, 0.0), (-0.5, 0.0, 0.0)),
        "LegR": ((0.5, hip, 0.0), (0.5, 0.0, 0.0)),
    }


# area04 toy_figure arm directions (local, forward = -Z), mirrored from _figure_arm.
_A4_POSE_ANGLE = {"pickaxe": 60.0, "clipboard": -20.0, "megaphone": 15.0, "wave": 80.0}


def a4_bones(xf, left_arm: str = "down", right_arm: str = "down") -> dict:
    """
    Skeleton of area04's Xf-based `toy_figure` (boots 0..0.6, legs to y 2.3, belt 2.42, torso to
    4.42, neck 4.45, head to ~6.3; shoulders at (+-1.45, 4.1)), transformed by the figure's Xf.
    left_arm / right_arm: the same pose names toy_figure got (decides where the hand bone ends).
    """

    def hand(side: int, pose: str):
        sx = side * 1.45
        if pose == "down":
            return (sx, 2.3, 0.0)
        a = math.radians(_A4_POSE_ANGLE.get(pose, 80.0))
        d = Vector((0.0, math.sin(a), -math.cos(a)))
        h = Vector((sx, 4.1, 0.0)) + d * 1.9
        return (h.x, h.y, h.z)

    local = {
        "Torso": ((0.0, 2.3, 0.0), (0.0, 4.45, 0.0)),
        "Head": ((0.0, 4.45, 0.0), (0.0, 6.3, 0.0)),
        "ArmL": ((-1.45, 4.1, 0.0), hand(-1, left_arm)),
        "ArmR": ((1.45, 4.1, 0.0), hand(1, right_arm)),
        "LegL": ((-0.52, 2.3, 0.0), (-0.52, 0.0, 0.0)),
        "LegR": ((0.52, 2.3, 0.0), (0.52, 0.0, 0.0)),
    }
    return {g: (xf.p(*a), xf.p(*b)) for g, (a, b) in local.items()}


__all__ = ["GROUPS", "rig_split", "a1_bones", "a4_bones"]
