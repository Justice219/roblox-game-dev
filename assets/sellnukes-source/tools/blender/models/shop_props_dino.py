"""
shop_props_dino.py — Dino Valley (World 2, owner R57) props for the Shop's rotating ViewportFrames
(owner R39 "in the shop we should use real 3d models"). W5's ShopConfig maps the Dino products
`BonesSmall` / `BonesMedium` / `BonesLarge` / `TimeTravelerPack` to these keys, exactly like the
main-world packs use the props in `shop_props.py`.

    Shop_BonesSmall        "Pile of Bones": three smooth chunky cartoon fossil dog-bones loosely crossed
                           (one on its edge at the back, two tipped across it at +-55 deg), an amber glint
                           streak on both faces of every bone, one tiny amber Neon sparkle.
    Shop_BonesMedium       "Sack of Bones": a lumpy sand mound with seven bones (two stuck upright in the
                           sand at the edge, two lying flat, one on the slope, one bridging them on its
                           edge, one tumbled on top), two amber nuggets with light facets, a fern sprout.
    Shop_BonesLarge        "Crate of Bones": a woven leaf basket (fern-green body, lime weave checker,
                           bamboo rim) overflowing with ten bones standing in a bone-shade heap (six lean
                           out over the rim, four taller ones in the middle, all twisted so they cross),
                           two cut amber gems and two tiny Neon sparkles (glow budget R19).
    Shop_TimeTravelerPack  one-time pack (Bones + Time Ptero pet + 2x boost): a toy-gold pocket watch on
                           its edge whose BOTH faces are a purple dial with a cyan time spiral, white Roman
                           numerals XII / III / VI / IX and 10:10 hands; a bundle of three bones tied with
                           an amber band and a speckled lavender ptero egg stand beside it.

Contract (identical to `shop_props.py`, see its header): Roblox space (studs, +Y up), PIVOT = ground
centre under the prop (every builder ends with `_recentre`: bounding box centred on X / Z, lowest point
y = 0), FRONT faces -Z (+X is the prop's right = the viewer's LEFT when looking at the front). Props are
~1.6-3.4 studs tall and decorated front AND back because the shop turntable spins them about +Y (camera
pitch 14 deg, ModelViewportLogic.Config). Budgets: <= 2,000 triangles, <= 12 pieces. One colour per
piece; StudsSmall on every main surface (small props), Smooth only for tiny glints / numerals / hands,
Neon only for sparkles far below NeonMaxArea (6 studs^2, owner R19).

Kid rules (spec 2026-10-31-world2-design.md §2): "Bones" are cartoon fossil dog-bones (cream with an
amber glint). No skulls, no teeth, no claws. Piece names avoid WorldFx words (Rocket, Glow, Core, Wheel,
Fan, Crystal, Liquid, Swirl, ...), so nothing here moves or emits a WorldFx light.

Bone LOD: a smooth knob needs <= 35 deg between neighbouring faces (snkit.export.SHARP_ANGLE). `_knob`
"hi" is a revolve with 30 deg steps on its visible outer side only (its inner cap is buried in the shaft
and the other knob): 88 tris, 418 a bone. Heaps cannot afford that, so they use "lo" (8-sided knobs, 224
a bone) or "min" (7-sided, 196). Heaps are framed smaller in the viewport, so their facets never read.

Bones are stacked by `_Pile.drop`: each bone falls straight down until one of its proxy spheres (knobs +
shaft samples) touches the ground surface or a bone already in the pile, so nothing floats or sinks.

Example (build + look):
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only Shop_BonesSmall
    python3 tools/blender/contact_sheet.py --only Shop_BonesSmall
"""

from __future__ import annotations

import math

from mathutils import Matrix, Vector

from snkit.core import Model, br, rb
from snkit.kit import block
from snkit.shapes import cylinder, ellipsoid, revolve, ring_tube, rot_x, rot_y, rot_z

from models._critter_kit import SNOW, oriented_ellipsoid, plate, star_outline, tube
from models.shop_props import GOLD_LIGHT, TOY_GOLD, _egg_profile, _recentre, _ribbon, _segment, _verts_from

# ------------------------------------------------------------------------------------------------
# Dino Valley shop palette (spec §2: fern green / sand / mossy stone / amber orange / bone cream /
# lava candy-orange). Main colours stay candy-vivid like the R47 colour pass in shop_props.py.
# ------------------------------------------------------------------------------------------------
BONE_CREAM = (255, 242, 206)  # every bone (the Bones currency look)
BONE_SHADE = (242, 208, 146)  # heap filler under the bones in the basket (reads as bones in shadow)
AMBER = (255, 140, 16)  # amber-orange glints, nuggets, gems, bundle tie
AMBER_LIGHT = (255, 206, 84)  # lighter amber facets on nuggets / gems (never brown)
SPARKLE_AMBER = (255, 196, 90)  # tiny Neon sparkle stars (warm, soft; glow budget R19)
SAND = (246, 196, 104)  # sand mound (Medium)
FERN = (62, 178, 70)  # basket body, fern sprout
FERN_LIGHT = (156, 226, 70)  # basket weave checker
BAMBOO = (238, 204, 92)  # basket rim
DIAL_PURPLE = (108, 52, 216)  # pocket-watch dial
TIME_CYAN = (40, 214, 255)  # time spiral on the dial + ptero egg speckles
EGG_LAVENDER = (200, 160, 255)  # Time Ptero egg shell

# Bone detail levels: (knob rings, knob segments, shaft segments). "hi" ignores rings (see _knob).
#   hi  -> smooth: 4 x 88 + 66 = 418 tris a bone (Small)
#   lo  -> 8-sided knobs: 4 x 48 + 32 = 224 tris; 128 with one end only (Medium, Large)
#   min -> 7-sided knobs: 4 x 42 + 28 = 196 tris (the pack's little bundle)
BONE_DETAIL = {
    "hi": (0, 11, 11),
    "lo": (4, 8, 8),
    "min": (4, 7, 7),
}
KNOB_OFFSET = 0.55  # each knob sits this many knob radii off the bone axis (the two overlap: one "heart" end)
KNOB_FLAT = 0.86  # knobs are squashed to this along the bone's face normal (a chunkier, flatter cartoon end)


# ------------------------------------------------------------------------------------------------
# Bone helpers
# ------------------------------------------------------------------------------------------------


def _pose(yaw: float = 0.0, pitch: float = 0.0, roll: float = 0.0):
    """
    Orientation of a bone built along +X with its two end lobes stacked along +Y (the dog-bone
    silhouette faces -Z / +Z). roll spins it about its own axis (90 = lobes side by side, lying flat),
    pitch raises the +X end (degrees), yaw turns it about +Y (positive = counter-clockwise from
    above, so yaw 90 points the +X end at the front, -Z).

    Example: _pose(yaw=20, pitch=-15)  # turned 20 deg, -X end raised 15 deg
    """
    return rot_y(yaw) @ rot_z(pitch) @ rot_x(roll)


class Bone:
    """
    Where a built bone ended up: centre, unit axis / lobe / normal vectors, half = centre-to-knob-centre
    distance along the axis, knob and shaft radii. Glints and ties use it to sit on the bone's surface.
    """

    def __init__(self, centre, rot, half: float, knob_r: float, shaft_r: float):
        self.centre = Vector(centre)
        self.axis = rot @ Vector((1, 0, 0))
        self.lobe = rot @ Vector((0, 1, 0))
        self.normal = rot @ Vector((0, 0, 1))
        self.half = half
        self.knob_r = knob_r
        self.shaft_r = shaft_r

    def at(self, t: float) -> Vector:
        """Point on the shaft axis at t (-1 .. 1 = knob centre to knob centre)."""
        return self.centre + self.axis * (t * self.half)

    def proxies(self, ends=(-1, 1)) -> list:
        """
        Collision proxy spheres [(centre, radius, t)]: every knob (slightly shrunk, they are flattened
        along the normal) plus shaft samples every ~0.8 shaft radii; t (-1 .. 1) is where along the
        bone the sphere sits (the pile's settle test needs supports on both sides of the middle).
        """
        out = []
        for s in ends:
            for k in (-1, 1):
                out.append((self.at(s) + self.lobe * (k * self.knob_r * KNOB_OFFSET), self.knob_r * 0.93, float(s)))
        # The shaft always spans the full length (a half-buried bone's shaft runs into the heap).
        steps = max(2, int(2 * self.half / (self.shaft_r * 0.8)))
        for i in range(steps + 1):
            t = -1.0 + 2.0 * i / steps
            out.append((self.at(t), self.shaft_r, t))
        return out


def _knob(piece, centre: Vector, out: Vector, normal: Vector, r: float, detail: str):
    """
    One round knob of a bone end, squashed to KNOB_FLAT along the bone's face normal.

    hi : revolve about `out` (the knob's outward direction) with 30 deg steps from the outer pole to
         125 deg, then straight to the inner pole: smooth-shaded where it shows, cheap where it is
         buried in the shaft / the other knob (11 segments -> 88 tris).
    lo / min : faceted UV ellipsoid (rings x segments from BONE_DETAIL).
    """
    rings, segments, _ = BONE_DETAIL[detail]
    start = len(piece.bm.verts)
    if detail == "hi":
        profile = [(0.0, r)]
        for a in (30, 60, 90, 125):
            t = math.radians(a)
            profile.append((r * math.sin(t), r * math.cos(t)))
        profile.append((0.0, -r))
        rot = Vector((0, 1, 0)).rotation_difference(out).to_matrix()
        revolve(piece, profile, center=tuple(centre), segments=segments, rot=rot)
    else:
        oriented_ellipsoid(piece, tuple(centre), (r, r, r), normal=tuple(normal), up=tuple(out), rings=rings, segments=segments)
    # Squash along the face normal (keeps the knob centre fixed).
    for v in _verts_from(piece, start):
        p = Vector(br(v.co))
        d = p - centre
        p = centre + d - normal * (d.dot(normal) * (1.0 - KNOB_FLAT))
        v.co = rb(tuple(p))


def _bone(piece, centre, rot, length: float, knob_r: float, shaft_r: float, detail: str = "lo", ends=(-1, 1)) -> Bone:
    """
    One chunky cartoon fossil dog-bone: a round shaft (gently waisted at "hi") from knob centre to
    knob centre, and at each end two round knobs side by side along the bone's lobe direction.

    centre  bone centre (Roblox space); rot = _pose(...) orientation
    length  distance between the two ends' knob centres (overall length = length + 2 * knob_r)
    ends    which ends get knobs: (-1, 1) a whole bone, (1,) a bone whose -X end is buried in a mound
            or heap (saves 2 knobs; its shaft still runs the full length, so nothing hangs in the air)

    Returns a Bone (final placement) for glints / ties / stacking.

    Example: _bone(bones, (0, 0.47, 0.4), _pose(yaw=-12), 2.0, 0.3, 0.2, "hi")
    """
    _, _, shaft_segments = BONE_DETAIL[detail]
    bone = Bone(centre, rot, length / 2, knob_r, shaft_r)
    half = bone.half
    # Shaft: revolve about local Y, re-oriented so local Y = the bone axis.
    if detail == "hi":
        profile = [(0.0, -half), (shaft_r * 1.1, -half), (shaft_r * 0.92, 0.0), (shaft_r * 1.1, half), (0.0, half)]
    else:
        profile = [(0.0, -half), (shaft_r, -half), (shaft_r, half), (0.0, half)]
    shaft_rot = Vector((0, 1, 0)).rotation_difference(bone.axis).to_matrix()
    revolve(piece, profile, center=tuple(bone.centre), segments=shaft_segments, rot=shaft_rot)
    # Knobs: two per end, KNOB_OFFSET knob radii either side of the axis, pointing outward-diagonal.
    for s in ends:
        end = bone.at(s)
        for k in (-1, 1):
            out = (bone.axis * s + bone.lobe * (k * 0.8)).normalized()
            _knob(piece, end + bone.lobe * (k * knob_r * KNOB_OFFSET), out, bone.normal, knob_r, detail)
    return bone


class _Pile:
    """
    Stacks bones without floating or sinking: `drop` lowers a bone straight down onto the ground
    surface (`ground(x, z)` -> height, minus `sink` so bones bed into sand) or onto any bone already
    dropped, using each bone's proxy spheres. With `settle` > 0 the pitch is searched within
    +-settle degrees for the pose that rests on supports on BOTH sides of the bone's middle (a bone
    across another tips until one end touches down, instead of balancing on one point).

    Example:
        pile = _Pile(lambda x, z: 0.0)
        a = pile.drop(bones, 0.1, 0.4, _pose(yaw=-10), 2.0, 0.3, 0.2, "hi")
        b = pile.drop(bones, 0.0, -0.3, _pose(yaw=60), 2.0, 0.3, 0.2, "hi", settle=30)  # tips over a
    """

    def __init__(self, ground, sink: float = 0.0):
        self.ground = ground
        self.sink = sink
        self.spheres = []

    def add(self, bone: Bone, ends=(-1, 1)):
        """Register a bone placed by hand (e.g. one poking out of a mound) so later drops rest on it."""
        self.spheres.extend((c, r) for c, r, _ in bone.proxies(ends))

    def rest(self, probe: Bone, ends=(-1, 1)) -> tuple:
        """
        (centre height, wobble) for `probe` (built at y = 0): the lowest height that clears the ground
        and the pile, and how far it is from resting on supports either side of its middle (0 = stable:
        the closest-to-touching sphere with t < 0.15 and the one with t > -0.15 both touch).
        """
        needs = []
        for c, r, t in probe.proxies(ends):
            need = self.ground(c.x, c.z) - self.sink + r - c.y
            for oc, orad in self.spheres:
                reach = r + orad
                dxz = math.hypot(c.x - oc.x, c.z - oc.z)
                if dxz < reach:
                    need = max(need, oc.y + math.sqrt(reach * reach - dxz * dxz) - c.y)
            needs.append((need, t))
        y = max(n for n, _ in needs)
        left = min(y - n for n, t in needs if t < 0.15)
        right = min(y - n for n, t in needs if t > -0.15)
        return y, left + right

    def drop(self, piece, x: float, z: float, rot, length: float, knob_r: float, shaft_r: float, detail: str, ends=(-1, 1), settle: float = 0.0) -> Bone:
        """
        Build a bone at (x, z) at the height where it first touches the ground or the pile. settle > 0
        tries extra pitches (3 deg steps, +-settle) about the bone's own centre and keeps the most
        stable one (ties -> the pitch closest to the requested pose).
        """
        best = None
        steps = int(settle // 3)
        # Tilt about the horizontal line across the bone (world space), so the roll is kept.
        axis = rot @ Vector((1, 0, 0))
        across = axis.cross(Vector((0, 1, 0)))
        across = across.normalized() if across.length > 1e-6 else Vector((0, 0, 1))
        for i in range(-steps, steps + 1):
            tilt = Matrix.Rotation(math.radians(3.0 * i), 3, across) @ rot
            y, wobble = self.rest(Bone((x, 0.0, z), tilt, length / 2, knob_r, shaft_r), ends)
            score = (round(wobble, 3), abs(i))
            if best is None or score < best[0]:
                best = (score, y, tilt)
        _, y, tilt = best
        bone = _bone(piece, (x, y, z), tilt, length, knob_r, shaft_r, detail, ends)
        self.add(bone, ends)
        return bone


def _glint(piece, bone: Bone, t: float, sides=(-1, 1)):
    """
    Amber glint streak lying along the shaft at t (-1 .. 1) on the bone's face side(s) (+-normal),
    half sunk into the shaft, so the amber fleck shows from the front AND the back. 24 tris each.
    """
    for side in sides:
        n = bone.normal * side
        p = bone.at(t) + n * (bone.shaft_r * 0.86)
        radii = (bone.shaft_r * 0.34, bone.half * 0.26, bone.shaft_r * 0.3)
        oriented_ellipsoid(piece, tuple(p), radii, normal=tuple(n), up=tuple(bone.axis), rings=3, segments=6)


def _sparkle(piece, centre, size: float, thickness: float = 0.05):
    """
    Four-point sparkle star made of two crossed plates (one faces Z, one faces X), so it reads from
    every turntable angle. 56 tris. Neon only: keep size <= 0.3 (glow budget R19).
    """
    outline = star_outline(size, size * 0.3, points=4)
    plate(piece, outline, centre, (0, 0, -1), (0, 1, 0), thickness)
    plate(piece, outline, centre, (1, 0, 0), (0, 1, 0), thickness)


def _nugget(amber, light, centre, radii, spin: float):
    """
    Rough amber nugget: a faceted 7-sided pebble (42 tris) plus one lighter flat facet on its upper
    front and one on its upper back (12 tris each), so it twinkles from both sides of the turntable.
    spin turns the nugget about +Y (degrees).
    """
    rot = rot_y(spin)
    up = rot @ Vector((0.25, 1.0, 0.1))
    oriented_ellipsoid(amber, tuple(centre), radii, normal=tuple(rot @ Vector((0, 0, -1))), up=tuple(up), rings=4, segments=7)
    c = Vector(centre)
    for side in (-1, 1):
        n = (rot @ Vector((0.2 * side, 0.9, -0.55 * side))).normalized()
        p = c + Vector((n.x * radii[0], n.y * radii[1], n.z * radii[2])) * 0.9
        plate(light, [(-0.07, -0.05), (0.07, -0.05), (0.05, 0.06), (-0.05, 0.06)], tuple(p), tuple(n), (0, 1, 0), 0.04)


def _gem(amber, light, centre, size: float, normal, spin: float = 0.0):
    """
    Cut amber gem (brilliant-cut silhouette, 8 sides, 48 tris) whose flat table faces `normal`, plus
    a lighter amber four-point glint on the table (28 tris). Same profile as shop_props._diamond.
    """
    r = size / 2
    profile = [(0.0, -size * 0.55), (r, 0.0), (r, size * 0.07), (r * 0.6, size * 0.3), (0.0, size * 0.3)]
    n = Vector(normal).normalized()
    rot = Vector((0, 1, 0)).rotation_difference(n).to_matrix() @ rot_y(spin)
    revolve(amber, profile, center=tuple(centre), segments=8, rot=rot)
    tip = Vector(centre) + n * (size * 0.3 + 0.012)
    plate(light, star_outline(size * 0.24, size * 0.08, points=4), tuple(tip), tuple(n), (0, 1, 0), 0.03)


def _frond(piece, base, yaw: float, lean: float, length: float):
    """
    One flat fern frond (feather outline with three leaflet notches a side, 56 tris) rising from
    `base`, turned `yaw` degrees about +Y and leaning `lean` degrees outward from vertical.
    """
    w = length * 0.2
    left = [(-0.04, 0.0), (-w, 0.16), (-w * 0.35, 0.22), (-w * 1.05, 0.42), (-w * 0.35, 0.47), (-w * 0.8, 0.66), (-w * 0.2, 0.72)]
    pts = [(x, y * length) for x, y in left]
    outline = pts + [(0.0, length)] + [(-x, y) for x, y in reversed(pts)]
    out = rot_y(yaw) @ Vector((0, 0, -1))
    up = Vector((0, 1, 0)) * math.cos(math.radians(lean)) + out * math.sin(math.radians(lean))
    side = rot_y(yaw) @ Vector((1, 0, 0))
    plate(piece, outline, tuple(base), tuple(up.cross(side).normalized()), tuple(up), 0.05)


# ================================================================================================
# 1. Shop_BonesSmall
# ================================================================================================


def build_bones_small():
    """Three smooth chunky bones loosely crossed, amber glint streaks, one tiny amber Neon sparkle."""
    m = Model(
        "Shop_BonesSmall",
        "ground centre under the bone pile (lowest knob at y = 0); front faces -Z; shop viewport prop for "
        "the 'Pile of Bones' Bones pack; three cartoon fossil dog-bones loosely crossed",
        budget=2000,
    )
    bones = m.piece("Bones", BONE_CREAM, material="StudsSmall")
    glint = m.piece("AmberGlint", AMBER, material="Smooth")
    sparkle = m.piece("Sparkle", SPARKLE_AMBER, material="Neon")
    size = (2.0, 0.3, 0.2)  # length (knob centre to knob centre), knob radius, shaft radius
    pile = _Pile(lambda x, z: 0.0)
    # A: on its edge at the back (lobes upright: the dog-bone silhouette faces front + back).
    a = pile.drop(bones, 0.0, 0.38, _pose(yaw=-6), *size, "hi")
    # B: turned ~55 deg the other way, tipped across A (front-left end on the ground).
    b = pile.drop(bones, 0.1, -0.2, _pose(yaw=52, roll=-15), *size, "hi", settle=36)
    # C: across both from the front right, so the side views see a bone face-on too.
    c = pile.drop(bones, -0.15, -0.05, _pose(yaw=-62, roll=20), *size, "hi", settle=36)
    _glint(glint, a, 0.32)
    _glint(glint, b, -0.3)
    _glint(glint, c, 0.28)
    top = max(bone.at(t).y for bone in (a, b, c) for t in (-1, 1))
    _sparkle(sparkle, (0.55, top + 0.5, -0.3), 0.22)
    _recentre(m)
    return m


# ================================================================================================
# 2. Shop_BonesMedium
# ================================================================================================

MOUND = (1.5, 0.72, 1.25)  # sand mound radii (x, height, z)


def _mound_top(x: float, z: float) -> float:
    """Height of the (un-lumped) Medium sand mound above (x, z); 0 outside it."""
    q = 1.0 - (x / MOUND[0]) ** 2 - (z / MOUND[2]) ** 2
    return MOUND[1] * math.sqrt(max(q, 0.0))


def build_bones_medium():
    """A lumpy sand mound with seven tumbled bones, two amber nuggets and a fern sprout."""
    m = Model(
        "Shop_BonesMedium",
        "ground centre under the sand mound (y = 0); front faces -Z; shop viewport prop for the 'Sack of "
        "Bones' Bones pack; seven bones tumbled on a sand mound, two amber nuggets",
        budget=2000,
    )
    bones = m.piece("Bones", BONE_CREAM, material="StudsSmall")
    sand = m.piece("Sand", SAND, material="StudsSmall")
    amber = m.piece("Amber", AMBER, material="StudsSmall")
    light = m.piece("AmberLight", AMBER_LIGHT, material="Smooth")
    glint = m.piece("AmberGlint", AMBER, material="Smooth")
    fern = m.piece("Fern", FERN, material="StudsSmall")

    # Sand mound: a flattened, gently lumpy dome with a flat bottom at y = 0.
    def lumpy(x, y, z):
        a = math.atan2(z, x)
        wobble = 1.0 + 0.05 * math.sin(3.0 * a) + 0.03 * math.cos(5.0 * a)
        return (x * wobble, max(y, 0.0), z * wobble)

    ellipsoid(sand, (0.0, 0.0, 0.0), MOUND, rings=5, segments=14, deform=lumpy)

    size = (1.35, 0.23, 0.15)
    pile = _Pile(_mound_top, sink=0.06)
    # Two bones stuck in the sand at the mound's edge, leaning outward (only their top end shows;
    # the centre sits 0.15 above the sand so the buried end stays inside the mound, above y = 0).
    for x, z, yaw, lean in ((-0.9, -0.5, 205, 34), (0.9, 0.55, 25, 30)):
        axis = _pose(yaw=yaw, pitch=90 - lean) @ Vector((1, 0, 0))
        centre = Vector((x, _mound_top(x, z), z)) + axis * 0.15
        poke = _bone(bones, tuple(centre), _pose(yaw=yaw, pitch=90 - lean, roll=90), 1.1, 0.23, 0.15, "lo", ends=(1,))
        pile.add(poke, ends=(1,))
    placed = [
        # Bottom: two bones lying flat on the sand, front and back, turned different ways.
        pile.drop(bones, 0.15, -0.42, _pose(yaw=18, roll=90), *size, "lo", settle=15),
        pile.drop(bones, -0.1, 0.42, _pose(yaw=-30, roll=90), *size, "lo", settle=15),
        # A third one at the side, half on the slope.
        pile.drop(bones, 0.85, 0.05, _pose(yaw=100, roll=70), *size, "lo", settle=15),
        # Bridge: on its edge across the front and back bones (the X views see it face-on).
        pile.drop(bones, -0.05, 0.0, _pose(yaw=88), *size, "lo", settle=15),
        # Top: tumbled across the bridge, tipping onto the pile.
        pile.drop(bones, 0.1, -0.05, _pose(yaw=35, roll=-20), *size, "lo", settle=24),
    ]
    _glint(glint, placed[3], 0.3)
    _glint(glint, placed[4], -0.25)
    # Amber nuggets half sunk into the sand: front left and back right.
    _nugget(amber, light, (1.0, _mound_top(1.0, -0.5) + 0.04, -0.5), (0.25, 0.21, 0.23), 20)
    _nugget(amber, light, (-0.95, _mound_top(-0.95, 0.6) + 0.04, 0.6), (0.22, 0.19, 0.21), -35)
    # Fern sprout at the back right: three fronds fanning out.
    base = (-0.2, _mound_top(-0.2, 0.95) - 0.04, 0.95)
    for yaw in (-150, -30, 90):
        _frond(fern, base, yaw, 30, 0.7)
    _recentre(m)
    return m


# ================================================================================================
# 3. Shop_BonesLarge
# ================================================================================================

BASKET = (1.1, 1.38, 0.86)  # bottom radius, top radius, height
FILLER = (1.32, 0.5)  # filler mound radius, height above the basket top


def _filler_top(x: float, z: float) -> float:
    """Height of the bone-shade filler mound in the Large basket above (x, z)."""
    q = 1.0 - (x * x + z * z) / (FILLER[0] ** 2)
    return BASKET[2] - 0.05 + FILLER[1] * math.sqrt(max(q, 0.0))


def build_bones_large():
    """Woven leaf basket heaped with ten bones, two cut amber gems and two tiny Neon sparkles."""
    m = Model(
        "Shop_BonesLarge",
        "ground centre under the basket (y = 0); front faces -Z; shop viewport prop for the 'Crate of "
        "Bones' Bones pack; woven leaf basket heaped with ten bones; Sparkle = tiny Neon accents",
        budget=2000,
    )
    bones = m.piece("Bones", BONE_CREAM, material="StudsSmall")
    filler = m.piece("BoneShade", BONE_SHADE, material="StudsSmall")
    body = m.piece("Basket", FERN, material="StudsSmall")
    weave = m.piece("Weave", FERN_LIGHT, material="StudsSmall")
    rim = m.piece("Rim", BAMBOO, material="StudsSmall")
    amber = m.piece("Amber", AMBER, material="StudsSmall")
    light = m.piece("AmberLight", AMBER_LIGHT, material="Smooth")
    sparkle = m.piece("Sparkle", SPARKLE_AMBER, material="Neon")

    # Basket: an eight-panel woven tub, wider at the top (flat panels read as woven leaf strips).
    r_bottom, r_top, height = BASKET
    revolve(
        body,
        [(0.0, 0.0), (r_bottom - 0.08, 0.0), (r_bottom, 0.08), (r_top, height), (r_top - 0.18, height), (0.0, height - 0.05)],
        segments=8,
    )
    # Weave checker: lime strips on alternate panels in two rows, leaning out with the wall.
    lean = math.degrees(math.atan2(r_top - r_bottom, height))
    for row, y in enumerate((0.27, 0.6)):
        for k in range(8):
            if (k + row) % 2:
                continue
            a = 2 * math.pi * (k + 0.5) / 8  # panel centre (the revolve's corners sit at k / 8)
            r = (r_bottom + (r_top - r_bottom) * (y / height)) * math.cos(math.pi / 8)  # panel apothem
            rot = rot_y(-math.degrees(a)) @ rot_z(-lean)
            width = 2 * r * math.tan(math.pi / 8) * 0.9
            block(weave, (r * math.cos(a), y, r * math.sin(a)), (0.12, 0.3, width), bevel=0.0, rot=rot)
    # Bamboo rim: a chunky octagonal ring round the top.
    ring_tube(rim, (0.0, height + 0.02, 0.0), r_top - 0.04, 0.24, 0.2, segments=8)
    # Filler mound inside the basket (the heap's shadowy depths).
    ellipsoid(filler, (0.0, height - 0.05, 0.0), (FILLER[0], FILLER[1], FILLER[0]), rings=4, segments=10, deform=lambda x, y, z: (x, max(y, -0.05), z))

    size = (1.4, 0.23, 0.15)

    def sticking_out(azimuth: float, r0: float, lean: float, twist: float, length: float) -> Bone:
        """
        A bone standing in the heap: its shaft leaves the filler at radius r0 / `azimuth`, leaning
        `lean` deg from vertical toward azimuth + `twist` (twisted bones cross their neighbours, so
        the heap reads as a jumble, not a bouquet). Its centre sits 0.15 above the filler along the
        axis, so most of the shaft shows and the buried end stays inside the basket.
        """
        d = rot_y(azimuth) @ Vector((1, 0, 0))
        rot = _pose(yaw=azimuth + twist, pitch=90 - lean, roll=90)
        start = Vector((d.x * r0, _filler_top(d.x * r0, d.z * r0), d.z * r0))
        centre = start + (rot @ Vector((1, 0, 0))) * 0.15
        return _bone(bones, tuple(centre), rot, length, size[1], size[2], "lo", ends=(1,))

    # Outer ring: six bones leaning out over the rim (an overflowing basket from every side).
    for k in range(6):
        sticking_out(60 * k + 10, 0.75, 44 + 6 * (k % 3), 28 * (1 if k % 2 else -1), 1.55)
    # Inner ring: four taller, more upright bones in the middle of the heap.
    for k in range(4):
        sticking_out(90 * k + 40, 0.3, 16 + 4 * (k % 2), 35, 1.85)
    # Two cut amber gems wedged into the heap between the outer bones (azimuth 40 and 220 deg), tables
    # tilted out toward the camera on either side.
    for azimuth, size_gem in ((40, 0.46), (220, 0.42)):
        d = rot_y(azimuth) @ Vector((1, 0, 0))
        at = d * 0.82
        _gem(amber, light, (at.x, _filler_top(at.x, at.z) + 0.08, at.z), size_gem, (d.x * 0.7, 0.75, d.z * 0.7))
    # Tiny Neon sparkles just above the gems (both inside a ~2.5 x 1 box: far under NeonMaxArea).
    for azimuth, height, size_s in ((40, 1.95, 0.2), (220, 2.05, 0.16)):
        d = rot_y(azimuth) @ Vector((1, 0, 0))
        _sparkle(sparkle, (d.x * 1.0, height, d.z * 1.0), size_s)
    _recentre(m)
    return m


# ================================================================================================
# 4. Shop_TimeTravelerPack
# ================================================================================================


def _roman(numeral: str, h: float, w: float) -> list:
    """
    Outlines (stroke rectangles) of a Roman numeral made of I / V / X, centred on (0, 0), height h,
    stroke width w. Letters are laid out left to right in plate space (+x = the viewer's right).

    Example: _roman("XII", 0.26, 0.06) -> 4 stroke outlines (X = 2 crossing strokes, I, I)
    """
    widths = {"I": w, "V": h * 0.72, "X": h * 0.72}
    gap = w * 0.9
    total = sum(widths[ch] for ch in numeral) + gap * (len(numeral) - 1)
    x = -total / 2
    lo, hi = -h / 2 + w * 0.35, h / 2 - w * 0.35
    out = []
    for ch in numeral:
        cw = widths[ch]
        cx = x + cw / 2
        if ch == "I":
            out.append(_segment((cx, -h / 2), (cx, h / 2), w))
        elif ch == "V":
            out.append(_segment((cx - cw / 2 + w / 2, hi), (cx, -h / 2 + w * 0.2), w))
            out.append(_segment((cx + cw / 2 - w / 2, hi), (cx, -h / 2 + w * 0.2), w))
        else:  # X
            out.append(_segment((cx - cw / 2 + w / 2, lo), (cx + cw / 2 - w / 2, hi), w))
            out.append(_segment((cx - cw / 2 + w / 2, hi), (cx + cw / 2 - w / 2, lo), w))
        x += cw + gap
    return out


def _shift(outline: list, dx: float, dy: float) -> list:
    """Translate a 2-D outline (lays a numeral out at its clock position on the dial)."""
    return [(x + dx, y + dy) for x, y in outline]


def build_time_traveler_pack():
    """Gold pocket watch on its edge (purple dial, cyan time spiral, Roman numerals, 10:10 hands both faces), bone bundle, ptero egg."""
    radius, thick = 1.0, 0.44
    cy = radius  # watch centre height: the rim touches the ground
    m = Model(
        "Shop_TimeTravelerPack",
        "ground centre under the pack (lowest point y = 0); front faces -Z; shop viewport prop for the one-time "
        "Time Traveler Pack; gold pocket watch on its edge with a dial on BOTH faces, bone bundle, ptero egg",
        budget=2000,
    )
    gold = m.piece("WatchGold", TOY_GOLD, material="StudsSmall")
    shine = m.piece("WatchShine", GOLD_LIGHT, material="Smooth")  # crown, bow, hands, centre cap
    dial = m.piece("Dial", DIAL_PURPLE, material="StudsSmall")
    spiral = m.piece("TimeSpiral", TIME_CYAN, material="Smooth")  # + the egg's speckles
    numerals = m.piece("Numerals", SNOW, material="Smooth")
    bones = m.piece("Bones", BONE_CREAM, material="StudsSmall")
    tie = m.piece("BundleTie", AMBER, material="StudsSmall")
    shell = m.piece("EggShell", EGG_LAVENDER, material="StudsSmall")

    c = Vector((0.0, cy, 0.0))
    face_r = radius * 0.84
    b = 0.08
    # Gold case: bevelled ring whose axis is Z (rot_x(90) turns the revolve's Y axis into +Z).
    revolve(
        gold,
        [
            (face_r - 0.05, -thick / 2),
            (radius - b, -thick / 2),
            (radius, -thick / 2 + b),
            (radius, thick / 2 - b),
            (radius - b, thick / 2),
            (face_r - 0.05, thick / 2),
        ],
        center=tuple(c),
        segments=20,
        closed=True,
        rot=rot_x(90),
    )
    # Dial: one purple disc through the case (shows on both faces), recessed inside the bezel.
    dial_depth = thick * 0.62
    circle = [(face_r * math.cos(2 * math.pi * i / 20), face_r * math.sin(2 * math.pi * i / 20)) for i in range(20)]
    plate(dial, circle, tuple(c), (0, 0, -1), (0, 1, 0), dial_depth)
    # Time spiral: one cyan ribbon (1.5 turns) through the dial, proud of both faces.
    path = []
    for i in range(15):
        t = i / 14
        a = math.radians(90 + 540 * t)
        r = 0.2 + (face_r - 0.3) * t
        path.append((r * math.cos(a), r * math.sin(a)))
    plate(spiral, _ribbon(path, 0.09), tuple(c), (0, 0, -1), (0, 1, 0), dial_depth + 0.03)
    # Numerals + hands: separate thin plates on EACH face so both read correctly (10:10, XII on top).
    face_z = dial_depth / 2 + 0.015
    ring = face_r * 0.68
    layout = (("XII", 0.0, ring), ("III", ring, 0.0), ("VI", 0.0, -ring), ("IX", -ring, 0.0))
    for side in (-1, 1):
        origin = (0.0, cy, side * (face_z + 0.02))
        for numeral, dx, dy in layout:
            for stroke in _roman(numeral, 0.24, 0.055):
                plate(numerals, _shift(stroke, dx, dy), origin, (0, 0, side), (0, 1, 0), 0.04)
        hand_origin = (0.0, cy, side * (face_z + 0.05))
        for angle, length, width in ((150, 0.42, 0.09), (30, 0.6, 0.07)):  # hour -> 10, minute -> 2
            a = math.radians(angle)
            tip = (length * math.cos(a), length * math.sin(a))
            nx, ny = -math.sin(a) * width / 2, math.cos(a) * width / 2
            outline = [(nx, ny), (tip[0] * 0.8 + nx, tip[1] * 0.8 + ny), tip, (tip[0] * 0.8 - nx, tip[1] * 0.8 - ny), (-nx, -ny)]
            plate(shine, outline, hand_origin, (0, 0, side), (0, 1, 0), 0.04)
    # Centre cap through the dial, crown stem + knob + bow loop on top.
    cylinder(shine, (0.0, cy, -(face_z + 0.09)), (0.0, cy, face_z + 0.09), 0.09, segments=10)
    top = cy + radius
    cylinder(gold, (0.0, top - 0.06, 0.0), (0.0, top + 0.16, 0.0), 0.1, segments=8)
    ellipsoid(shine, (0.0, top + 0.24, 0.0), (0.17, 0.12, 0.17), rings=4, segments=10)
    ring_tube(shine, (0.0, top + 0.56, 0.0), 0.22, 0.09, 0.11, segments=10, axis="Z")

    # Bone bundle at the watch's front right (viewer's right = -X): three small bones round a common
    # axis (one on top, two below), lobes pointing outward, tied round the middle with an amber band.
    frame = rot_y(30)  # +X end toward the front, so the bundle never touches the case
    centre = Vector((-1.42, 0.0, -0.36))
    start = len(bones.bm.verts)
    for angle in (0, 120, 240):
        rot = frame @ rot_x(angle)
        offset = rot @ Vector((0, 0.16, 0))
        _bone(bones, tuple(centre + offset), rot, 1.15, 0.2, 0.12, "min")
    lift = -min(br(v.co)[1] for v in _verts_from(bones, start))
    for v in _verts_from(bones, start):
        x, y, z = br(v.co)
        v.co = rb((x, y + lift, z))
    centre.y += lift
    band = [tuple(centre + frame @ Vector((0.0, 0.32 * math.cos(2 * math.pi * i / 6), 0.32 * math.sin(2 * math.pi * i / 6)))) for i in range(6)]
    tube(tie, band, 0.06, sides=5, closed=True)

    # Speckled Time Ptero egg at the watch's front left (+X).
    egg_h, egg_r = 1.12, 0.42
    profile, hb = _egg_profile(egg_h, egg_r)
    egg_base = Vector((1.3, 0.0, -0.2))
    revolve(shell, profile, center=tuple(egg_base), segments=10)
    for yaw_s, elev, spot in ((-20, 12, 0.15), (75, 38, 0.12), (160, 5, 0.15), (255, 32, 0.12), (25, 58, 0.1), (205, 60, 0.1)):
        e, y_r = math.radians(elev), math.radians(yaw_s)
        half = egg_h - hb
        horizontal = Vector((math.sin(y_r), 0.0, -math.cos(y_r)))
        local = horizontal * (egg_r * math.cos(e)) + Vector((0, hb + half * math.sin(e), 0))
        grad = Vector((local.x / egg_r**2, (local.y - hb) / half**2, local.z / egg_r**2)).normalized()
        oriented_ellipsoid(spiral, tuple(egg_base + local - grad * 0.02), (spot, spot * 0.9, 0.05), normal=tuple(grad), rings=3, segments=7)
    _recentre(m)
    return m


BUILDERS = {
    "Shop_BonesSmall": build_bones_small,
    "Shop_BonesMedium": build_bones_medium,
    "Shop_BonesLarge": build_bones_large,
    "Shop_TimeTravelerPack": build_time_traveler_pack,
}
