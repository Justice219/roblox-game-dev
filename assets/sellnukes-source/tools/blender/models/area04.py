"""
area04.py — Area 4 "Glow Rock Mine" (spec §3.4): a chunky stud cave with glowing green crystals,
mine carts on a track, timber support beams and a big yellow drill. Every pad purchase is its own
model set so each one builds in separately; placement lives in src/shared/Config/AreaLayouts/Area04.luau.

Also hosts the SHARED toy helpers used by area05.py / area06.py (toy_figure, crystal, Xf, _hash),
so every manager / worker figure across areas 4-6 has the same proportions.

Every model has its OWN pivot (ground centre unless stated, front = -Z). The layout places it
with a slot-local CFrame (slot +Z points away from the road, so identity rotation faces the road);
models that stand on the area floor are placed at y = 0.4 (floor top).

Models (key: pivot / notes)                                     build key
    A4_Floor        slab centre at ground; top y = 0.4               base
    A4_EntryArch    ground centre of the walkway opening; double-    base
                    sided "GLOW ROCK / MINE" block letters (R17)
    A4_CaveSideR    the +X side cliff (inner face toward -X);        base
                    A4_CaveSideL is its mirror for the -X side
    A4_CaveBack     back cliff with the cart tunnel at local x=-22   A4_MineEntrance
    A4_GlowDrill    PRODUCER "Glow Rock Drill"; Rotor = drill auger  A4_MineEntrance
    A4_BeamFrame    timber goalpost frame over the walkway           A4_SupportBeams
    A4_Miner        toy miner swinging a pickaxe at the glow rock     A4_PickaxeCrew
                    (R75: rig-split; Pick + Lean hinged WorldFx groups)
    A4_CartTrack    straight rails along local Z, buffer + ore bin   A4_CartTrack
    A4_MineCart     cart with a crystal load; pivot = rail top       A4_CartTrack
                    (R56: WheelsF/WheelsR + HubsF/HubsR per axle, z -1.2 / 1.2)
    A4_DrillRig     lattice derrick; Rotor = the big auger           A4_DrillRig
    A4_CrystalLamp  timber lamp post; Glow centre = PointLight spot  A4_CrystalLamps
    A4_GlowVein     erupting crystal cluster                         A4_GlowVein
    A4_ForemanShack foreman's timber shack, "FOREMAN" board (R17)    A4_Foreman
    A4_Foreman      Manager NPC figure ONLY (R30: client walks it)   A4_Foreman

Animation contract = piece NAMES resolved by src/shared/Config/WorldFxConfig.luau (B4). The client
moves each tagged piece about ITS OWN bounding-box centre with a random phase per piece, so:
    Rotor   spin about local Y -> every Rotor is rotationally symmetric about a vertical axis
            through its bbox centre (auger flights in equal angle steps over 360 deg).
    Glow    glowing gems: bob +-0.3 + a pulsing PointLight at the piece centre. Every Glow gem is
            rooted >= 0.4 studs into its OWN model's rock (never shows a gap) or floats free (lamp
            and lantern cages: GlowL / GlowR resolve to Glow too).
    Crystal glowing gems embedded in the cave cliffs: a pulsing light only, they NEVER move (the
            floor-level clusters stand on the floor, so a bob would lift them off it).
    Neon    static Neon (miner headlamp) — deliberately NOT an FX word, it must not bob off the hat.
    Gem     stud-textured crystal bodies — NOT an FX word.

Glow budget (owner R19): Neon only on small accents (largest box face <= 6 studs², the
MeshPlacement.NeonMaxArea rule): lamp / lantern / cart / miner gems and the producer's hero tips.
Glows spread over a big piece (cliff crystals, the vein, the derrick mound) are authored as Smooth
GLOW_SOFT, which is what the runtime would render them as anyway, so previews match the game.
    Mine carts ride VehicleRoutes (R56). The miners swing their picks through WorldFx hinged
    swing groups (owner R75, build_miner).

Budgets: shell/cliff pieces <= 4,000 triangles, machines <= 4,000, hero rig <= 6,000, props <= 3,000.
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import (
    CHARCOAL,
    CREAM,
    DARK_STEEL,
    DEEP_BLUE,
    GLOW_GREEN,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    Model,
    ORANGE,
    STEEL,
    TOY_RED,
    WHITE,
    WOOD,
    WOOD_DARK,
    YELLOW,
)
from snkit.kit import block, disc, hazard_band, ladder, sign_frame, truss
from snkit.shapes import bar, box, cylinder, ellipsoid, revolve, rot_x, rot_y, rot_z

from models.area01 import sign_text  # shared double-sided block lettering (owner R17)

# ------------------------------------------------------------------------------------------------
# Area-local palette (candy-toy mine colours; the global palette lives in snkit/core.py).
# ------------------------------------------------------------------------------------------------

ROCK = (232, 172, 104)  # warm sandy stud rock (reference: sell-lemons 18 crypto cave)
ROCK_DARK = (196, 136, 80)  # accent blocks / boulders
DIRT = (214, 158, 98)  # cave floor
DIRT_DARK = (184, 130, 80)  # floor patches
STONE = (176, 170, 160)  # flagstone walkway
CRYSTAL = (110, 236, 130)  # stud-textured crystal bodies (Neon is reserved for small glow tips)
SKIN = (246, 196, 146)  # toy figure skin
TUNNEL = (34, 30, 36)  # near-black tunnel throat (Smooth, no studs)
# Soft glow for big spread-out glow pieces (R19): GLOW_GREEN lifted toward white, rendered Smooth.
GLOW_SOFT = (150, 250, 132)

FLOOR_TOP = 0.4  # area floor top; models standing on the floor are placed at y = FLOOR_TOP


# ------------------------------------------------------------------------------------------------
# Shared helpers (also imported by area05.py / area06.py)
# ------------------------------------------------------------------------------------------------


def _hash(i: float, k: float = 0.0) -> float:
    """
    Deterministic pseudo-random number in [0, 1) from two seeds. Builders must be deterministic
    (same geometry -> same piece hashes -> no re-upload), so no `random` module state is used.

    Example: _hash(3, 1) -> 0.41...  (always the same value)
    """
    v = math.sin(i * 12.9898 + k * 78.233) * 43758.5453
    return v - math.floor(v)


class Xf:
    """
    Local -> model transform for sub-assemblies (figures, clusters): yaw (degrees, CCW from above)
    about +Y, then translate to `base`. Lets one helper draw a figure anywhere, facing anywhere.

    Example:
        xf = Xf((4, 0, -2), yaw=90)          # sub-assembly at (4, 0, -2), its front (-Z) turned to -X
        block(piece, xf.p(0, 1, 0), (1, 2, 1), rot=xf.rot)
    """

    def __init__(self, base, yaw: float = 0.0):
        self.base = Vector(base)
        self.rot = rot_y(yaw)

    def p(self, x: float, y: float, z: float) -> tuple:
        """Transform a local point to model space."""
        v = self.rot @ Vector((x, y, z)) + self.base
        return (v.x, v.y, v.z)

    def r(self, local_rot=None):
        """Compose a local rotation matrix with this transform's yaw."""
        return self.rot if local_rot is None else self.rot @ local_rot


def crystal(piece, base, height: float, radius: float, tilt_x: float = 0.0, tilt_z: float = 0.0, segments: int = 6):
    """
    Chunky hexagonal toy crystal: a prism with a pointed tip, rooted slightly below `base` so it
    never floats, tilted `tilt_x` then `tilt_z` degrees. 6 segments = cheap and reads as a gem.

    Example: crystal(glow, (0, 0.4, 0), 3.0, 0.5, tilt_x=12)
    """
    tip = min(radius * 1.5, height * 0.45)
    profile = [
        (0.0, -0.4),
        (radius * 0.8, -0.4),
        (radius, 0.0),
        (radius, height - tip),
        (0.0, height),
    ]
    revolve(piece, profile, center=base, segments=segments, rot=rot_z(tilt_z) @ rot_x(tilt_x))


def crystal_cluster(body, glow, center, scale: float = 1.0, seed: int = 0, count: int = 5, glow_count: int = 2):
    """
    A cluster of stud crystals (body piece) fanning outward plus a few small Neon tips (glow piece).
    Neon is used sparingly on purpose: a couple of glowing gems per cluster read as "glowing rock"
    without blowing out the bloom. Base centre = `center` (crystals root at its y).
    """
    cx, cy, cz = center
    for i in range(count):
        a = 2 * math.pi * (i / count) + _hash(seed, i) * 0.8
        r = 0.6 * scale * (0.4 + _hash(seed + 7, i))
        h = scale * (1.6 + 2.2 * _hash(seed + 3, i)) * (1.25 if i == 0 else 1.0)
        tx = 26 * math.sin(a) * (0.5 + _hash(seed + 5, i))
        tz = -26 * math.cos(a) * (0.5 + _hash(seed + 5, i))
        rad = scale * (0.32 + 0.22 * _hash(seed + 9, i))
        if i == 0:  # the hero crystal stands up the middle
            tx, tz, r = tx * 0.2, tz * 0.2, 0.0
        crystal(body, (cx + r * math.cos(a), cy, cz + r * math.sin(a)), h, rad, tilt_x=tx, tilt_z=tz)
    for i in range(glow_count):
        a = 2 * math.pi * (i + 0.5) / max(glow_count, 1) + _hash(seed + 11, i)
        r = 0.75 * scale
        crystal(
            glow,
            (cx + r * math.cos(a), cy, cz + r * math.sin(a)),
            scale * (1.0 + 0.8 * _hash(seed + 13, i)),
            scale * 0.2,
            tilt_x=-30 * math.cos(a),
            tilt_z=30 * math.sin(a),
        )


def rock_lump(rock, dark, center, size, seed: int = 0, steps: int = 2):
    """
    Stepped LEGO rock: a beveled block with one or two smaller, offset blocks stacked on top
    (alternating rock / dark accent pieces by hash). `center` = bottom centre. Cheap (44 tris/step).
    """
    cx, cy, cz = center
    sx, sy, sz = size
    y = cy
    for s in range(steps):
        shrink = 1.0 - 0.28 * s
        h = sy * (0.62 if s == 0 else 0.38)
        ox = (_hash(seed, s) - 0.5) * sx * 0.25 * s
        oz = (_hash(seed + 1, s) - 0.5) * sz * 0.25 * s
        piece = dark if (_hash(seed + 2, s) > 0.6 and dark is not None) else rock
        block(piece, (cx + ox, y + h / 2, cz + oz), (sx * shrink, h, sz * shrink), bevel=0.35)
        y += h


def toy_figure(
    pieces: dict,
    xf: Xf,
    hat: str = "hardhat",
    right_arm: str = "down",
    left_arm: str = "down",
    vest: bool = False,
    coat: bool = False,
    tie: bool = False,
    headlamp: bool = False,
):
    """
    Chunky toy worker figure (~6.3 studs tall incl. hat), feet at xf's base, facing local -Z.

    pieces: {"skin", "shirt", "pants", "dark", "hat"} required; optional
            "tool" (pickaxe / megaphone piece; default "dark"), "board" + "paper" (clipboard),
            "accent" (vest stripes / tie), "glow" (headlamp: pass a STATIC Neon piece, e.g. named
            "Neon", never "Glow" — Glow pieces bob), "coat" (lab coat), "hair", "goggles".
    hat:    "hardhat" | "hair" (wild scientist hair + goggles) | "cap"
    right_arm / left_arm: "down" | "pickaxe" (raised, holding a pickaxe) | "clipboard" (bent
            forward holding a board) | "wave" (raised high) | "megaphone"
    Figures are static on purpose: the FX controller turns pieces about their own bbox centre,
    so a sleeve + tool can never swing about a shared shoulder hinge.

    Example:
        toy_figure({"skin": skin, "shirt": shirt, "pants": pants, "dark": dark, "hat": hat},
                   Xf((0, 0, 0), yaw=0), right_arm="clipboard")
    """
    skin, shirt, pants, dark, hatp = pieces["skin"], pieces["shirt"], pieces["pants"], pieces["dark"], pieces["hat"]
    rot = xf.rot
    # Boots + legs.
    for s in (-1, 1):
        block(dark, xf.p(s * 0.52, 0.3, -0.12), (0.98, 0.6, 1.3), bevel=0.15, rot=rot)
        block(pants, xf.p(s * 0.52, 1.45, 0), (0.92, 1.7, 0.96), bevel=0.12, rot=rot)
    # Belt + torso.
    block(dark, xf.p(0, 2.42, 0), (2.12, 0.36, 1.06), bevel=0.1, rot=rot)
    block(shirt, xf.p(0, 3.5, 0), (2.1, 1.84, 1.04), bevel=0.22, rot=rot)
    if coat and "coat" in pieces:
        # Lab-coat tails flaring below the belt + lapels.
        coatp = pieces["coat"]
        block(coatp, xf.p(0, 1.75, 0.02), (2.3, 1.5, 1.16), bevel=0.15, rot=rot)
        block(coatp, xf.p(0, 3.5, 0.03), (2.22, 1.9, 1.1), bevel=0.2, rot=rot)
    if vest and "accent" in pieces:
        for y in (3.05, 3.75):
            block(pieces["accent"], xf.p(0, y, 0), (2.18, 0.24, 1.12), bevel=0.05, rot=rot)
    if tie and "accent" in pieces:
        block(pieces["accent"], xf.p(0, 3.6, -0.55), (0.34, 1.3, 0.08), bevel=0.04, rot=rot)
        block(pieces["accent"], xf.p(0, 4.22, -0.55), (0.5, 0.3, 0.1), bevel=0.04, rot=rot)
    # Head (toy cylinder), neck, face.
    cylinder(skin, xf.p(0, 4.38, 0), xf.p(0, 4.62, 0), 0.42, segments=10)
    revolve(skin, [(0.0, 0.0), (0.66, 0.0), (0.74, 0.12), (0.74, 1.18), (0.66, 1.3), (0.0, 1.3)], center=xf.p(0, 4.55, 0), segments=12, rot=rot)
    for s in (-1, 1):
        block(dark, xf.p(s * 0.26, 5.32, -0.72), (0.16, 0.3, 0.08), bevel=0.03, rot=rot)
    bar(dark, xf.p(-0.26, 4.98, -0.72), xf.p(-0.1, 4.88, -0.72), 0.09)
    bar(dark, xf.p(-0.1, 4.88, -0.72), xf.p(0.1, 4.88, -0.72), 0.09)
    bar(dark, xf.p(0.1, 4.88, -0.72), xf.p(0.26, 4.98, -0.72), 0.09)
    # Hat / hair.
    if hat == "hardhat":
        revolve(
            hatp,
            [(0.0, 0.62), (0.42, 0.6), (0.7, 0.42), (0.8, 0.12), (1.02, 0.06), (1.04, -0.04), (0.0, -0.04)],
            center=xf.p(0, 5.82, 0),
            segments=14,
            rot=rot,
        )
        block(hatp, xf.p(0, 6.2, 0), (0.3, 0.3, 1.5), bevel=0.06, rot=rot)  # ridge
        if headlamp and "glow" in pieces:
            revolve(
                pieces["glow"],
                [(0.0, -0.08), (0.24, -0.08), (0.24, 0.08), (0.0, 0.08)],
                center=xf.p(0, 6.05, -0.78),
                segments=10,
                rot=xf.r(rot_x(90)),
            )
    elif hat == "cap":
        revolve(hatp, [(0.0, 0.45), (0.6, 0.4), (0.78, 0.0), (0.0, 0.0)], center=xf.p(0, 5.82, 0), segments=12, rot=rot)
        block(hatp, xf.p(0, 5.86, -0.9), (1.3, 0.12, 0.8), bevel=0.04, rot=rot)  # peak
    elif hat == "hair":
        hair = pieces.get("hair", hatp)
        # Wild cartoon-scientist hair: tufts around the sides/back, bald-ish top.
        for k in range(7):
            a = math.radians(-20 + k * 35)
            hx, hz = 0.7 * math.sin(a), 0.7 * math.cos(a)
            ellipsoid(hair, xf.p(hx, 5.55 + 0.12 * (k % 2), hz), (0.42, 0.36, 0.42), rings=4, segments=8)
        if "goggles" in pieces:
            gog = pieces["goggles"]
            block(dark, xf.p(0, 5.62, -0.1), (1.56, 0.22, 1.56), bevel=0.06, rot=rot)  # strap
            for s in (-1, 1):
                revolve(
                    gog,
                    [(0.0, -0.12), (0.28, -0.12), (0.3, 0.12), (0.0, 0.12)],
                    center=xf.p(s * 0.32, 5.62, -0.78),
                    segments=10,
                    rot=xf.r(rot_x(90)),
                )
    # Arms (sleeves in the coat colour when the figure wears one).
    _figure_arm(pieces, xf, -1, left_arm)
    _figure_arm(pieces, xf, 1, right_arm)


def _figure_arm(pieces: dict, xf: Xf, side: int, pose: str):
    """
    One arm of toy_figure (side -1 = left, +1 = right). See toy_figure for poses. The arm is a
    sleeve block rotated so its long axis points along the pose direction `d` from the shoulder
    (local (side * 1.45, 4.1, 0)), with the hand at the end and any held tool beyond it.
    """
    sleeve = pieces.get("coat") or pieces["shirt"]
    hand = pieces["skin"]
    tool = pieces.get("tool") or pieces["dark"]
    sx = side * 1.45
    if pose == "down":
        block(sleeve, xf.p(sx, 3.35, 0), (0.74, 1.7, 0.82), bevel=0.14, rot=xf.rot)
        block(hand, xf.p(sx, 2.3, 0), (0.62, 0.5, 0.64), bevel=0.12, rot=xf.rot)
        return
    if pose == "pickaxe":
        d = Vector((0.0, math.sin(math.radians(60)), -math.cos(math.radians(60))))  # forward-up
        angle = 60.0
    elif pose == "clipboard":
        d = Vector((0.0, -math.sin(math.radians(20)), -math.cos(math.radians(20))))  # forward, a bit down
        angle = -20.0
    elif pose == "megaphone":
        d = Vector((0.0, math.sin(math.radians(15)), -math.cos(math.radians(15))))
        angle = 15.0
    else:  # "wave"
        d = Vector((0.0, math.sin(math.radians(80)), -math.cos(math.radians(80))))
        angle = 80.0
    local_rot = rot_x(angle - 90.0)  # local arm block's long axis (Y) -> along d (forward = -Z)
    mid = Vector((sx, 4.1, 0)) + d * 0.85
    block(sleeve, xf.p(mid.x, mid.y, mid.z), (0.74, 1.7, 0.82), bevel=0.14, rot=xf.r(local_rot))
    hand_c = Vector((sx, 4.1, 0)) + d * 1.9
    block(hand, xf.p(hand_c.x, hand_c.y, hand_c.z), (0.62, 0.62, 0.62), bevel=0.12, rot=xf.r(local_rot))
    if pose == "pickaxe":
        # Toy pickaxe: short chunky handle along the arm, a fat curved head across its end.
        a = hand_c - d * 0.35
        b = hand_c + d * 1.7
        bar(tool, xf.p(a.x, a.y, a.z), xf.p(b.x, b.y, b.z), 0.3)
        perp = Vector((0.0, -d.z, d.y))  # perpendicular to the handle, in the swing (YZ) plane
        block(tool, xf.p(b.x, b.y, b.z), (0.5, 0.62, 0.62), bevel=0.1, rot=xf.r(local_rot))  # head socket
        for tipdir in (-1, 1):
            # Each half of the head tapers and curves back toward the handle (cartoon pick).
            t0 = b + perp * tipdir * 0.25
            t1 = b + perp * tipdir * 1.25 - d * 0.25
            t2 = b + perp * tipdir * 1.85 - d * 0.7
            cylinder(tool, xf.p(t0.x, t0.y, t0.z), xf.p(t1.x, t1.y, t1.z), 0.3, segments=6, radius_b=0.24)
            cylinder(tool, xf.p(t1.x, t1.y, t1.z), xf.p(t2.x, t2.y, t2.z), 0.24, segments=6, radius_b=0.05)
    elif pose == "clipboard":
        board = pieces.get("board") or pieces["dark"]
        paper = pieces.get("paper") or pieces["hat"]
        bc = hand_c + Vector((-side * 0.7, 0.35, -0.2))
        block(board, xf.p(bc.x, bc.y, bc.z), (1.5, 1.9, 0.14), bevel=0.05, rot=xf.r(rot_x(-25)))
        block(paper, xf.p(bc.x, bc.y + 0.05, bc.z - 0.1), (1.2, 1.5, 0.06), bevel=0.02, rot=xf.r(rot_x(-25)))
    elif pose == "megaphone":
        a = hand_c + d * 0.1
        b = hand_c + d * 1.6
        cylinder(tool, xf.p(a.x, a.y, a.z), xf.p(b.x, b.y, b.z), 0.28, segments=10, radius_b=0.75)


# ------------------------------------------------------------------------------------------------
# Base: floor, entry arch, side cliffs
# ------------------------------------------------------------------------------------------------

SLOT_W = 104.0
SLOT_D = 70.0


def build_floor():
    """Cave floor slab for the whole slot + flagstone walkway from the road to the producer."""
    m = Model("A4_Floor", "slab centre at ground (place at slot (0, 0, 35)); top y = 0.4", budget=3000)
    dirt = m.piece("Dirt", DIRT)
    patch = m.piece("Patch", DIRT_DARK)
    stone = m.piece("Stone", STONE)
    # Full slot width (x +-52): the neighbouring rows' floors butt this one edge to edge. At
    # SLOT_W - 0.4 a 0.2-stud strip of plot grass showed between the areas (World-QA, A1-art).
    block(dirt, (0, FLOOR_TOP / 2, 0), (SLOT_W, FLOOR_TOP, SLOT_D - 0.4), bevel=0.15)
    # Darker dirt patches (flat, slightly raised) break up the big plain floor.
    for i, (x, z, sx, sz) in enumerate(
        ((-36, 8, 14, 9), (-2, -6, 10, 7), (-18, 22, 9, 7), (40, -10, 10, 12), (-42, -16, 9, 8), (14, -26, 12, 6))
    ):
        block(patch, (x, FLOOR_TOP + 0.04, z), (sx, 0.12, sz), bevel=0.04, rot=rot_y(15 * (_hash(i, 2) - 0.5)))
    # Flagstone walkway: road edge (z = -35) to the producer (z ~ +1), x in [-6, 6].
    z = -34.0
    k = 0
    while z < 0.5:
        length = 3.4 + 1.2 * _hash(k, 4)
        for s, w in ((-1, 5.6), (1, 5.6)):
            block(stone, (s * 3.0, FLOOR_TOP + 0.08, z + length / 2), (w, 0.2, length - 0.35), bevel=0.08)
        z += length
        k += 1
    return m


SIGN_Y = 19.4  # arch sign board centre (bottom edge 16.5, clear of the header beams)
SIGN_Z = -0.4
LETTER_GREEN = (46, 150, 70)  # Smooth block letters on the cream board (not Neon: R19)


def build_entry_arch():
    """Rock pillars + timber header + area-name sign + crystals; opening 14 wide x 13 high."""
    m = Model("A4_EntryArch", "ground centre of the walkway opening; double-sided sign, front -Z (road)", budget=4500)
    rock = m.piece("Rock", ROCK)
    dark = m.piece("RockDark", ROCK_DARK)
    timber = m.piece("Timber", WOOD)
    timber_dark = m.piece("TimberDark", WOOD_DARK)
    board = m.piece("Board", CREAM, material="Smooth")
    letters = m.piece("Letters", LETTER_GREEN, material="Smooth")
    body = m.piece("Gem", CRYSTAL)
    # R19: one small Neon piece per lantern gem (a shared piece would span 9 studs and render as
    # Smooth). Both resolve to the Glow FX row: they bob inside their cages and carry the light.
    lanterns = {-1: m.piece("GlowL", GLOW_GREEN, material="Neon"), 1: m.piece("GlowR", GLOW_GREEN, material="Neon")}
    iron = m.piece("Iron", DARK_STEEL, material="StudsSmall")
    for s in (-1, 1):
        x = s * 10.0
        # Stacked rock pillar: three shrinking stepped blocks.
        block(rock, (x, 3.0, 0), (6.0, 6.0, 5.6), bevel=0.4)
        block(dark, (x + s * 0.3, 8.6, 0.2), (5.2, 5.2, 5.0), bevel=0.4)
        block(rock, (x - s * 0.2, 12.4, 0), (4.6, 2.6, 4.6), bevel=0.35)
        block(dark, (x + s * 2.1, 1.3, -2.4), (2.6, 2.6, 2.0), bevel=0.3)  # boulder, proud of the pillar (R18)
        # Pillar-top crystals are all studded Gem (their old glow tip sat 20 studs from the other).
        crystal_cluster(body, body, (x, 13.6, 0), scale=1.0, seed=int(20 + s), count=4, glow_count=1)
    # Timber header (two beams) resting on the pillars, iron straps.
    block(timber, (0, 14.4, 0), (25.0, 1.6, 2.0), bevel=0.2)
    block(timber_dark, (0, 15.7, 0.2), (22.0, 1.0, 1.6), bevel=0.15)
    for x in (-7.0, 7.0):
        block(iron, (x, 14.4, 0), (0.5, 1.8, 2.2), bevel=0.05)
    # Inner timber jambs framing the opening.
    for s in (-1, 1):
        block(timber, (s * 7.4, 6.8, -1.0), (1.2, 13.6, 1.2), bevel=0.15)
        bar(timber_dark, (s * 7.4, 11.0, -1.0), (s * 4.6, 13.6, -1.0), 0.6)
    # Sign board above the header with DOUBLE-SIDED block letters (owner R17: reads correctly from
    # the road AND from inside the mine). Board centre z = SIGN_Z; letters sit on both board faces.
    sign_frame(timber_dark, board, (0, SIGN_Y, SIGN_Z), (17.0, 5.8), border=0.6, depth=0.7)
    sign_text(letters, ["GLOW ROCK", "MINE"], (0, SIGN_Y, SIGN_Z), 0.28, 0.22, 0.245)
    for s in (-1, 1):
        bar(timber_dark, (s * 6.5, 16.0, SIGN_Z), (s * 6.5, SIGN_Y - 2.6, SIGN_Z), 0.5)
    # Two hanging lanterns with glowing crystals.
    for s in (-1, 1):
        x = s * 4.2
        bar(iron, (x, 13.6, -1.2), (x, 12.4, -1.2), 0.12)
        block(iron, (x, 12.3, -1.2), (1.0, 0.2, 1.0), bevel=0.04)
        block(iron, (x, 10.2, -1.2), (1.0, 0.2, 1.0), bevel=0.04)
        for sx in (-1, 1):
            bar(iron, (x + sx * 0.4, 10.3, -1.2), (x + sx * 0.4, 12.2, -1.2), 0.1)
        # Floating gem: the Glow bob (+-0.3) stays between the cage plates.
        crystal(lanterns[s], (x, 11.0, -1.2), 0.9, 0.3)
    return m


def _cave_side(key: str, mirror: float):
    """
    Side cliff along local Z (z in [-19, 19]), inner face toward -X (mirror = -1 flips to +X).
    Heights rise from ~8 at the road end (-Z) to ~24 at the back (+Z), stepped LEGO rock.
    """
    m = Model(
        key,
        "ground; wall occupies local x in [-9, 0] (+X side wall, inner face -X)"
        if mirror > 0
        else "ground; wall occupies local x in [0, 9] (-X side wall, inner face +X)",
        budget=4000,
    )
    rock = m.piece("Rock", ROCK)
    dark = m.piece("RockDark", ROCK_DARK)
    body = m.piece("Gem", CRYSTAL)
    glow = m.piece("Crystal", GLOW_SOFT, material="Smooth")  # R19 soft glow; static (see module doc)
    edges = [-19.0, -12.5, -6.0, 0.5, 6.5, 12.5, 19.0]
    for i in range(len(edges) - 1):
        z0, z1 = edges[i], edges[i + 1]
        zc = (z0 + z1) / 2
        t = (zc + 19) / 38
        h = 8.0 + 15.0 * t + 3.0 * _hash(i, 31)
        w = z1 - z0
        layers = (
            (h * 0.58, 8.6, 0.0, rock if i % 2 == 0 else dark),
            (h * 0.27, 6.8, 0.6, dark if i % 2 == 0 else rock),
            (h * 0.15, 4.6, 1.4, rock),
        )
        y = 0.0
        for lh, depth, inset, piece in layers:
            x_c = mirror * (-depth / 2)
            block(piece, (x_c, y + lh / 2, zc), (depth, lh, w - inset), bevel=0.4)
            y += lh
        # Boulder at the inner foot of every other column.
        if i % 2 == 1:
            block(dark, (mirror * -9.6, 1.1, zc + (_hash(i, 5) - 0.5) * 3), (2.6, 2.2, 2.8), bevel=0.35)
    # Two small crystal clusters growing out of the inner face. The floor-level one is based 0.4 up
    # so its 0.4-stud roots end ON the cave floor (A4_Floor is another model: no buried overlap, R24).
    crystal_cluster(body, glow, (mirror * -8.6, 0.4, -9.0), scale=0.8, seed=int(40 + 3 * mirror), count=3, glow_count=1)
    crystal_cluster(body, glow, (mirror * -6.8, 14.0, 9.5), scale=0.9, seed=int(50 + 3 * mirror), count=4, glow_count=1)
    return m


def build_cave_side_r():
    return _cave_side("A4_CaveSideR", 1.0)


def build_cave_side_l():
    return _cave_side("A4_CaveSideL", -1.0)


# ------------------------------------------------------------------------------------------------
# A4_MineEntrance: back cliff with the cart tunnel + the producer
# ------------------------------------------------------------------------------------------------

TUNNEL_X = -22.0  # local x of the tunnel mouth (= slot x; the cart track lines up with it)


def build_cave_back():
    """Back cliff (x in [-52, 52], z in [-6, 6]) with a timber-framed tunnel mouth at x = -22."""
    m = Model("A4_CaveBack", "ground centre of the cliff (place at slot (0, 0, 64)); tunnel at local x = -22", budget=4000)
    rock = m.piece("Rock", ROCK)
    dark = m.piece("RockDark", ROCK_DARK)
    timber = m.piece("Timber", WOOD)
    timber_dark = m.piece("TimberDark", WOOD_DARK)
    throat = m.piece("Tunnel", TUNNEL, material="Smooth")
    body = m.piece("Gem", CRYSTAL)
    glow = m.piece("Crystal", GLOW_SOFT, material="Smooth")  # R19 soft glow; static (see module doc)
    edges = [-51.8, -44.0, -36.0, -28.0, -16.0, -6.0, 4.0, 14.0, 24.0, 34.0, 44.0, 51.8]
    opening_top = 12.4
    for i in range(len(edges) - 1):
        x0, x1 = edges[i], edges[i + 1]
        xc, w = (x0 + x1) / 2, x1 - x0
        h = 21.0 + 7.0 * _hash(i, 17)
        tunnel = x0 <= TUNNEL_X <= x1
        layers = [
            (0.0, h * 0.6, 12.0, 0.0, rock if i % 2 == 0 else dark),
            (h * 0.6, h * 0.85, 10.0, 0.6, dark if i % 2 == 0 else rock),
            (h * 0.85, h, 7.2, 1.4, rock),
        ]
        for y0, y1, depth, inset, piece in layers:
            if tunnel and y0 < opening_top:
                y0 = opening_top  # leave the tunnel mouth open below the lintel
            if y1 <= y0:
                continue
            block(piece, (xc, (y0 + y1) / 2, 6.0 - depth / 2), (w - inset, y1 - y0, depth), bevel=0.4)
        # Boulders along the foot (skip the tunnel mouth so carts can roll out, and the two end
        # columns |x| > 42: the side cliffs A4_CaveSideL/R stand there, R24 no interpenetration).
        if not tunnel and i % 3 != 2 and abs(xc) < 42.0:
            block(dark, (xc + (_hash(i, 3) - 0.5) * w * 0.5, 1.2, -6.6), (3.0, 2.4, 2.4), bevel=0.35)
    # Tunnel: dark throat + two timber frames (front and inside).
    box(throat, (TUNNEL_X, 6.2, 4.0), (10.0, 12.4, 4.0))
    for z, post in ((-6.2, 1.5), (-1.0, 1.2)):
        for s in (-1, 1):
            block(timber, (TUNNEL_X + s * 4.9, 5.9, z), (post, 11.8, post), bevel=0.15)
        block(timber_dark, (TUNNEL_X, 12.3, z), (12.4, 1.4, post + 0.2), bevel=0.15)
    for s in (-1, 1):
        bar(timber_dark, (TUNNEL_X + s * 4.9, 9.4, -6.2), (TUNNEL_X + s * 2.6, 11.7, -6.2), 0.6)
    # Glow crystals inside the tunnel + on the cliff face.
    # Floor-level clusters are based 0.4 up so their roots end on the cave floor (R24).
    crystal_cluster(body, glow, (TUNNEL_X + 2.6, 0.4, 1.0), scale=0.8, seed=61, count=3, glow_count=2)
    crystal_cluster(body, glow, (14.0, 15.5, -1.0), scale=1.0, seed=62, count=4, glow_count=1)
    crystal_cluster(body, glow, (-42.0, 13.0, -0.5), scale=0.9, seed=63, count=4, glow_count=1)
    crystal_cluster(body, glow, (38.0, 0.4, -7.0), scale=1.1, seed=64, count=5, glow_count=2)
    return m


def build_glow_drill():
    """
    PRODUCER "Glow Rock Drill": a glowing crystal boulder under a yellow gantry with a blue motor
    and a spinning auger (Rotor), a crystal chute into a red bin and a control panel.
    Footprint ~16 x 10; motor top y ~ 17.5.
    """
    m = Model("A4_GlowDrill", "ground centre; front -Z; Rotor axis at local (0, *, 1.5)", budget=4500)
    base = m.piece("Base", DARK_STEEL)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    rock = m.piece("Rock", ROCK)
    dark = m.piece("RockDark", ROCK_DARK)
    body = m.piece("Gem", CRYSTAL)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")  # hero tips only: <= 6 studs² box face (R19)
    frame = m.piece("Frame", YELLOW)
    motor = m.piece("Motor", DEEP_BLUE)
    rotor = m.piece("Rotor", STEEL, material="StudsSmall")
    red = m.piece("Bin", TOY_RED)
    # Steel base plate with a hazard band along its front edge.
    block(base, (0, 0.35, 1.0), (13.0, 0.7, 9.0), bevel=0.2)
    hazard_band(yellow, black, (0, 0.35, -3.56), (12.4, 0.5, 0.16), stripe=0.7)
    # Glow rock boulder with crystals sprouting from it.
    rock_lump(rock, dark, (0, 0.7, 1.6), (8.0, 6.0, 6.4), seed=71, steps=2)
    crystal_cluster(body, glow, (-2.6, 4.2, 0.0), scale=1.0, seed=72, count=4, glow_count=2)
    crystal_cluster(body, body, (2.8, 3.6, 3.0), scale=0.85, seed=73, count=3, glow_count=1)
    # Gantry: two legs + header beam, feet with hazard collars.
    for s in (-1, 1):
        x = s * 5.6
        block(base, (x, 1.1, 1.5), (2.2, 0.8, 2.2), bevel=0.15)
        block(frame, (x, 7.4, 1.5), (1.5, 12.0, 1.5), bevel=0.2)
        bar(frame, (x, 10.0, 1.5), (s * 3.2, 12.6, 1.5), 0.8)
    block(frame, (0, 13.4, 1.5), (13.0, 1.8, 2.4), bevel=0.25)
    # Motor housing on top + exhaust stack + hazard band.
    block(motor, (0, 15.6, 1.5), (4.2, 2.8, 3.6), bevel=0.35)
    cylinder(base, (1.3, 16.8, 2.6), (1.3, 18.4, 2.6), 0.32, segments=8)
    hazard_band(yellow, black, (0, 14.7, -0.32), (4.0, 0.6, 0.12), stripe=0.5)
    # Rotor: shaft + 12 auger flights (rotated in 30 deg steps -> symmetric box) + cone tip.
    cylinder(rotor, (0, 5.4, 1.5), (0, 12.6, 1.5), 0.42, segments=10)
    for k in range(12):
        box(rotor, (0, 6.6 + k * 0.42, 1.5), (2.6, 0.18, 0.55), rot=rot_y(k * 30.0))
    cylinder(rotor, (0, 6.4, 1.5), (0, 4.6, 1.5), 0.9, segments=10, radius_b=0.12)
    # Crystal chute into a red bin on the right (+X), bin full of crystals.
    bar(base, (4.0, 4.0, 0.2), (7.0, 2.6, -1.4), 0.9)
    block(red, (8.0, 1.4, -1.6), (3.4, 2.4, 3.0), bevel=0.25)
    block(base, (8.0, 2.65, -1.6), (3.6, 0.2, 3.2), bevel=0.05)
    crystal_cluster(body, body, (8.0, 2.4, -1.6), scale=0.6, seed=74, count=3, glow_count=1)
    # Control panel on the left with a big red button.
    block(motor, (-7.6, 1.6, -1.2), (2.4, 3.2, 1.8), bevel=0.2)
    block(base, (-7.6, 3.3, -1.4), (2.6, 0.3, 2.0), bevel=0.05)
    disc(red, (-7.6, 3.42, -1.4), 0.55, 0.35, segments=12, bevel=0.1)
    return m


# ------------------------------------------------------------------------------------------------
# Pads
# ------------------------------------------------------------------------------------------------


def build_beam_frame():
    """Timber goalpost frame (clear span 15 x 12.4) with braces, iron straps and a crystal lantern."""
    m = Model("A4_BeamFrame", "ground centre; spans local x in [-9.5, 9.5]; walk through along Z", budget=2000)
    timber = m.piece("Timber", WOOD)
    timber_dark = m.piece("TimberDark", WOOD_DARK)
    iron = m.piece("Iron", DARK_STEEL, material="StudsSmall")
    stone = m.piece("Stone", ROCK_DARK)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    for s in (-1, 1):
        x = s * 8.2
        block(stone, (x, 0.6, 0), (2.6, 1.2, 2.6), bevel=0.3)
        block(timber, (x, 7.0, 0), (1.4, 12.8, 1.4), bevel=0.18)
        block(iron, (x, 12.5, 0), (1.6, 0.5, 1.6), bevel=0.05)
        bar(timber_dark, (x, 9.6, 0), (s * 5.2, 13.2, 0), 0.7)
    block(timber_dark, (0, 13.9, 0), (19.4, 1.6, 1.8), bevel=0.2)
    for x in (-3.0, 3.0):
        block(iron, (x, 13.9, 0), (0.4, 1.8, 2.0), bevel=0.04)
    # Lantern on a chain under the header.
    bar(iron, (0, 13.1, 0), (0, 11.7, 0), 0.12)
    block(iron, (0, 11.6, 0), (1.1, 0.22, 1.1), bevel=0.05)
    block(iron, (0, 9.2, 0), (1.1, 0.22, 1.1), bevel=0.05)
    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(iron, (sx * 0.45, 9.3, sz * 0.45), (sx * 0.45, 11.5, sz * 0.45), 0.1)
    # Floating gem: the Glow bob (+-0.3) stays between the cage plates.
    crystal(glow, (0, 10.05, 0), 0.95, 0.3)
    return m


def build_miner():
    """
    Toy miner (orange hi-vis vest, yellow hard hat with a static Neon headlamp) raising a pickaxe
    over the glow rock in front of him.

    Owner R75 ("animate the miners ... they don't actually do anything"): the figure is split into
    the R30 rig groups (models/_npc_rig.py: Torso* / Head* / ArmL* / ArmR* / LegL* / LegR*) so
    WorldFx can swing the pickaxe arm about the shoulder and lean the body about the hips. The rock
    and its glow gems stay whole and static (Rock, Glow). Same key, pivot, footprint and look as the
    static build; only the piece partition changed. Motion (WorldFxConfig Assemblies.A4_Miner):
        Pick  ArmRShirt / ArmRSkin / ArmRPick   PickSwing about the shoulder hinge MINER_SHOULDER
        Lean  Torso* / Head* / ArmL*            MinerLean about the hips MINER_HIP (Pick rides it)
    """
    from models._npc_rig import a4_bones, rig_split

    m = Model("A4_Miner", "feet centre; faces -Z; rock at local z = -3.4", budget=3000)
    pieces = {
        "skin": m.piece("Skin", SKIN, material="Smooth"),
        "shirt": m.piece("Shirt", ORANGE, material="StudsSmall"),
        "pants": m.piece("Pants", DEEP_BLUE, material="StudsSmall"),
        "dark": m.piece("Dark", CHARCOAL, material="Smooth"),
        "hat": m.piece("Hat", HAZARD_YELLOW, material="StudsSmall"),
        "glow": m.piece("Neon", GLOW_GREEN, material="Neon"),  # headlamp: rides the head, never bobs
        "tool": m.piece("Pick", STEEL, material="StudsSmall"),
    }
    pieces["accent"] = pieces["hat"]  # vest stripes share the hat's yellow (one draw call)
    xf = Xf((0, 0, 0))
    toy_figure(pieces, xf, hat="hardhat", right_arm="pickaxe", vest=True, headlamp=True)
    rock = m.piece("Rock", ROCK_DARK)
    rock_lump(rock, None, (0.4, 0.0, -3.4), (3.0, 2.4, 2.4), seed=81, steps=2)
    # The rock's glowing gems bob + light up (Glow), rooted 0.4 deep so they never float free.
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    crystal(glow, (1.1, 1.4, -3.6), 1.1, 0.26, tilt_x=-20, tilt_z=-15)
    crystal(glow, (-0.3, 1.6, -3.0), 0.8, 0.22, tilt_x=10, tilt_z=20)
    # Rig split (same recipe as the Foreman): the torso bone stops at the collar so the neck and
    # mouth bars classify with the head; the pick rides the right arm; the rock stays whole.
    bones = a4_bones(xf, "down", "pickaxe")
    bones["Torso"] = (bones["Torso"][0], xf.p(0.0, 4.0, 0.0))
    rig_split(m, bones, static=("Rock", "Glow"), assign={"Pick": "ArmR"}, frame=((0.0, 0.0, 0.0), 0.0))
    return m


# Hinges of the miner's motion groups (model space; WorldFxConfig.Assemblies.A4_Miner mirrors them).
MINER_SHOULDER = (1.45, 4.1, 0.0)  # right shoulder: the pickaxe arm swings about local X here
MINER_HIP = (0.0, 2.3, 0.0)  # hips: the body leans about local X here


def build_cart_track():
    """
    Straight mine-cart track along local Z (z in [-21, 21]); rail top at y = 0.6. The +Z end runs
    into the A4_CaveBack tunnel, the -Z end has a timber buffer stop and an ore bin.
    """
    m = Model("A4_CartTrack", "track centre at ground; rails along Z; rail top y = 0.6", budget=3000)
    rail = m.piece("Rail", STEEL, material="StudsSmall")
    sleeper = m.piece("Sleeper", WOOD_DARK)
    timber = m.piece("Timber", WOOD)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    body = m.piece("Gem", CRYSTAL)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    for s in (-1, 1):
        box(rail, (s * 1.4, 0.45, 0.5), (0.34, 0.3, 41.0))
        box(rail, (s * 1.4, 0.3, 0.5), (0.7, 0.12, 41.0))  # foot top 0.36: never on the sleeper plane (R18)
    z = -19.6
    while z <= 20.6:
        block(sleeper, (0, 0.15, z), (4.2, 0.3, 0.9), bevel=0.06)
        z += 2.0
    # Buffer stop at the front (-Z) end, hazard-striped.
    for s in (-1, 1):
        block(timber, (s * 1.6, 1.1, -20.6), (0.9, 2.2, 0.9), bevel=0.12)
    block(timber, (0, 2.0, -20.8), (4.4, 1.0, 0.8), bevel=0.12)
    hazard_band(yellow, black, (0, 2.0, -21.25), (4.2, 0.8, 0.12), stripe=0.5)
    # Ore bin beside the buffer, heaped with crystals.
    for s in (-1, 1):
        block(timber, (5.2, 1.3, -18.0 + s * 1.9), (4.0, 2.6, 0.5), bevel=0.1)
        block(timber, (5.2 + s * 1.85, 1.3, -18.0), (0.5, 2.6, 3.8), bevel=0.1)
    block(timber, (5.2, 0.2, -18.0), (3.6, 0.4, 3.6), bevel=0.06)
    crystal_cluster(body, glow, (5.2, 1.8, -18.0), scale=0.7, seed=91, count=4, glow_count=1)
    return m


def _hub_cross(hubs, x_face, z, radius):
    """
    Small point-symmetric steel hub (boss + 4-spoke cross) on BOTH outer wheel faces of one axle
    (faces at x = +-x_face), so the hubs piece's bbox centre is the axle point (0, radius, z) and
    the client can spin it with its wheels (R56). Used by A4_MineCart's flat iron wheels.
    """
    reach, spoke_w, boss_r = 0.62 * radius, 0.12, 0.2 * radius
    for sx in (-1, 1):
        x0 = sx * (x_face - 0.03)  # 0.03 inside the wheel face
        spoke_x = x0 + sx * 0.045  # spokes 0.06 proud, boss 0.09 proud (no shared planes)
        box(hubs, (spoke_x, radius, z), (0.09, 2 * reach, spoke_w))
        box(hubs, (spoke_x, radius, z), (0.09, spoke_w, 2 * reach))
        cylinder(hubs, (x0, radius, z), (sx * (x_face + 0.09), radius, z), boss_r, segments=8)


def build_mine_cart():
    """Red mine cart with iron rim, four wheels and a heap of crystals. Pivot = rail top centre.

    R56 drivable split: per-axle WheelsF (z -1.2) / WheelsR (z 1.2), r 0.55, each holding both
    wheels of its axle (bbox centre = axle point (0, 0.55, z)), plus small steel HubsF / HubsR
    crosses on the outer faces so the roll reads. Gem + Glow stay the ore load."""
    m = Model(
        "A4_MineCart",
        "rail-top centre (wheels on rails at x = +-1.4); front -Z; axles z -1.2 / 1.2, wheel r 0.55",
        budget=2000,
    )
    body_p = m.piece("Body", TOY_RED)
    rim = m.piece("Rim", DARK_STEEL, material="StudsSmall")
    body = m.piece("Gem", CRYSTAL, material="StudsSmall")
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    for suffix, z in (("F", -1.2), ("R", 1.2)):
        wheels = m.piece("Wheels" + suffix, CHARCOAL, material="Smooth")
        hubs = m.piece("Hubs" + suffix, STEEL, material="StudsSmall")
        # Flat iron wheels (sharp cylinders, x 1.25 .. 1.6) mirrored per axle; a small cross on the
        # outer face (embedded 0.03, 0.06 / 0.09 proud) so the client's spin is visible.
        for sx in (-1, 1):
            cylinder(wheels, (sx * 1.25, 0.55, z), (sx * 1.6, 0.55, z), 0.55, segments=12)
        _hub_cross(hubs, 1.6, z, 0.55)
    block(rim, (0, 0.95, 0), (3.0, 0.3, 3.8), bevel=0.08)
    # Body: slightly flared tub (two stacked blocks).
    block(body_p, (0, 1.75, 0), (3.2, 1.4, 4.0), bevel=0.25)
    block(body_p, (0, 2.75, 0), (3.6, 0.7, 4.4), bevel=0.2)
    block(rim, (0, 3.18, 0), (3.8, 0.22, 4.6), bevel=0.06)
    for s in (-1, 1):
        block(rim, (0, 1.9, s * 2.05), (0.5, 1.6, 0.2), bevel=0.04)
    block(body, (0, 3.2, 0), (3.0, 0.5, 3.8), bevel=0.15)
    for i, (x, z, h, tx, tz) in enumerate(
        ((-0.6, -0.9, 1.6, -15, 12), (0.7, 0.6, 1.9, 10, -14), (-0.4, 1.1, 1.2, 18, 10), (0.5, -1.2, 1.3, -12, -16))
    ):
        crystal(body, (x, 3.3, z), h, 0.42, tilt_x=tx, tilt_z=tz)
    crystal(glow, (0.0, 3.3, 0.0), 1.5, 0.3)
    crystal(glow, (-0.9, 3.3, 0.4), 0.9, 0.22, tilt_z=20)
    return m


def build_drill_rig():
    """
    Lattice derrick (~26 tall) over a crystal mound: yellow work deck, orange motor with hazard
    band, crown block, ladder, and the big auger (Rotor) boring into the glow rock.
    """
    m = Model("A4_DrillRig", "ground centre; Rotor axis at local (0, *, 0); motor top y ~ 26", budget=6000)
    truss_p = m.piece("Truss", DARK_STEEL, material="StudsSmall")
    deck = m.piece("Deck", YELLOW)
    motor = m.piece("Motor", ORANGE)
    yellow = m.piece("HazardYellow", HAZARD_YELLOW)
    black = m.piece("HazardBlack", HAZARD_BLACK)
    rotor = m.piece("Rotor", STEEL, material="StudsSmall")
    rock = m.piece("Rock", ROCK)
    dark = m.piece("RockDark", ROCK_DARK)
    body = m.piece("Gem", CRYSTAL)
    glow = m.piece("Glow", GLOW_SOFT, material="Smooth")  # R19: two tips 5 studs apart -> soft glow
    # Four corner trusses (legs) leaning in slightly, tied by the deck and the crown.
    for sx in (-1, 1):
        for sz in (-1, 1):
            truss(truss_p, (sx * 4.2, 0.0, sz * 4.2), (sx * 2.4, 22.0, sz * 2.4), 1.2, member=0.24, bays=6)
            block(dark, (sx * 4.2, 0.5, sz * 4.2), (2.4, 1.0, 2.4), bevel=0.2)
    # Work deck at y = 10 with a hazard-striped front edge and corner rails.
    block(deck, (0, 10.3, 0), (10.6, 0.6, 10.6), bevel=0.15)
    hazard_band(yellow, black, (0, 10.3, -5.36), (10.2, 0.5, 0.14), stripe=0.6)
    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(deck, (sx * 5.0, 10.6, sz * 5.0), (sx * 5.0, 12.2, sz * 5.0), 0.25)
    for s in (-1, 1):
        bar(deck, (-5.0, 12.2, s * 5.0), (5.0, 12.2, s * 5.0), 0.25)
        bar(deck, (s * 5.0, 12.2, -5.0), (s * 5.0, 12.2, 5.0), 0.25)
    # Crown + motor on top.
    block(deck, (0, 22.3, 0), (6.4, 0.6, 6.4), bevel=0.15)
    block(motor, (0, 24.0, 0), (4.2, 2.8, 4.2), bevel=0.4)
    hazard_band(yellow, black, (0, 23.0, -2.16), (4.0, 0.6, 0.12), stripe=0.5)
    cylinder(truss_p, (1.4, 25.4, 1.4), (1.4, 26.8, 1.4), 0.3, segments=8)
    ladder(truss_p, (0, 0.0, -4.9), 10.0, width=1.6, facing="z")
    # Rotor: long shaft + auger flights near the bottom + cone tip in the mound.
    cylinder(rotor, (0, 2.6, 0), (0, 22.3, 0), 0.5, segments=10)  # ends inside the crown deck (R18)
    for k in range(16):
        box(rotor, (0, 3.2 + k * 0.42, 0), (3.2, 0.2, 0.62), rot=rot_y(k * 22.5))
    cylinder(rotor, (0, 3.0, 0), (0, 0.8, 0), 1.0, segments=10, radius_b=0.15)
    # Crystal mound the auger bores into (rock ring + crystals between the legs).
    for i in range(6):
        a = 2 * math.pi * i / 6 + 0.3
        block(rock if i % 2 else dark, (2.6 * math.cos(a), 0.7, 2.6 * math.sin(a)), (2.4, 1.4, 2.4), bevel=0.3, rot=rot_y(-math.degrees(a)))
    crystal_cluster(body, glow, (2.2, 1.0, -2.0), scale=0.8, seed=101, count=3, glow_count=1)
    crystal_cluster(body, glow, (-2.4, 1.0, 1.8), scale=0.8, seed=102, count=3, glow_count=1)
    return m


def build_crystal_lamp():
    """Timber lamp post with a hanging iron lantern holding a glowing crystal (PointLight anchor)."""
    m = Model("A4_CrystalLamp", "ground centre; lamp faces -Z; Glow centre ~ (0, 5.85, -1.6) = PointLight anchor", budget=1500)
    timber = m.piece("Timber", WOOD)
    iron = m.piece("Iron", DARK_STEEL, material="StudsSmall")
    stone = m.piece("Stone", ROCK_DARK)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    block(stone, (0, 0.5, 0), (2.4, 1.0, 2.4), bevel=0.3)
    block(stone, (0.5, 0.35, 0.9), (1.2, 0.7, 1.2), bevel=0.2)
    block(timber, (0, 4.4, 0), (0.9, 8.0, 0.9), bevel=0.12)
    block(timber, (0, 8.0, -0.8), (0.8, 0.8, 2.4), bevel=0.12)
    bar(timber, (0, 6.6, 0), (0, 7.7, -1.4), 0.5)
    bar(iron, (0, 7.6, -1.6), (0, 7.0, -1.6), 0.1)
    block(iron, (0, 6.95, -1.6), (1.2, 0.22, 1.2), bevel=0.05)
    block(iron, (0, 4.95, -1.6), (1.2, 0.22, 1.2), bevel=0.05)
    for sx in (-1, 1):
        for sz in (-1, 1):
            bar(iron, (sx * 0.5, 5.0, -1.6 + sz * 0.5), (sx * 0.5, 6.9, -1.6 + sz * 0.5), 0.1)
    # Gem floats in the cage centre so the Glow bob (+-0.3) never clips the cage plates.
    crystal(glow, (0, 5.55, -1.6), 1.0, 0.34)
    return m


def build_glow_vein():
    """Erupting crystal cluster: stepped rock mound, big stud crystals, soft glowing gems (R19)."""
    m = Model("A4_GlowVein", "ground centre; ~8.7 x 7.4 footprint, ~9 tall", budget=3000)
    rock = m.piece("Rock", ROCK)
    dark = m.piece("RockDark", ROCK_DARK)
    body = m.piece("Gem", CRYSTAL)
    glow = m.piece("Glow", GLOW_SOFT, material="Smooth")  # R19: the whole vein glows -> soft glow
    rock_lump(rock, dark, (0, 0, 0.4), (7.4, 3.6, 6.6), seed=111, steps=2)
    block(dark, (-3.2, 0.9, -2.4), (2.4, 1.8, 2.2), bevel=0.3)
    block(rock, (3.0, 0.7, -2.6), (2.0, 1.4, 1.8), bevel=0.3)
    crystal_cluster(body, glow, (0.2, 3.0, 0.6), scale=1.7, seed=112, count=6, glow_count=3)
    crystal_cluster(body, glow, (-3.0, 1.6, -2.4), scale=0.8, seed=113, count=3, glow_count=1)
    crystal_cluster(body, glow, (3.0, 1.2, -2.6), scale=0.7, seed=114, count=3, glow_count=0)
    return m


def build_foreman_shack():
    """Foreman's timber shack: open front, counter, slanted red roof and a double-sided FOREMAN board."""
    m = Model("A4_ForemanShack", "ground centre of the shack; open side faces -Z", budget=3000)
    timber = m.piece("Timber", WOOD)
    timber_dark = m.piece("TimberDark", WOOD_DARK)
    roof = m.piece("Roof", TOY_RED)
    board = m.piece("Board", CREAM, material="Smooth")
    letters = m.piece("Letters", TOY_RED, material="Smooth")  # roof red on cream: reads from the walkway
    # Floor, back + side walls (plank look from alternating stacked blocks), corner posts.
    block(timber_dark, (0, 0.25, 1.0), (8.0, 0.5, 6.0), bevel=0.12)
    for k in range(4):
        y = 0.5 + 1.7 * k + 0.85
        block(timber if k % 2 == 0 else timber_dark, (0, y, 3.75), (8.0, 1.7, 0.5), bevel=0.12)
        for s in (-1, 1):
            block(timber if k % 2 else timber_dark, (s * 3.75, y, 1.25), (0.5, 1.7, 4.5), bevel=0.12)
    for s in (-1, 1):
        block(timber_dark, (s * 3.75, 4.3, -1.6), (0.8, 7.6, 0.8), bevel=0.12)
    block(timber, (0, 2.6, -1.4), (6.8, 0.4, 1.4), bevel=0.1)  # counter
    block(timber_dark, (0, 1.3, -1.6), (6.8, 2.2, 0.4), bevel=0.08)
    block(roof, (0, 8.6, 1.0), (9.4, 0.6, 7.6), bevel=0.2, rot=rot_x(-8))
    # Name board on two posts above the roof, lettered on both faces (R17). The board's visible
    # opening (8.2 - 2 x 0.35 = 7.5 x 1.3) holds "FOREMAN" (41 x 7 font cells at 0.17 = 6.97 x 1.19)
    # with a margin, so no letter runs under the frame. Posts start inside the slanted roof.
    sign_frame(timber_dark, board, (0, 10.4, -0.6), (8.2, 2.0), border=0.35, depth=0.5)
    sign_text(letters, "FOREMAN", (0, 10.4, -0.6), 0.17, 0.1, 0.175)
    for s in (-1, 1):
        bar(timber_dark, (s * 2.4, 8.5, -0.6), (s * 2.4, 9.6, -0.6), 0.3)
    return m


def build_foreman():
    """
    The Foreman (Manager NPC, owner R30): white hard hat, hi-vis vest, clipboard. Figure ONLY, so
    the client NPC animator can walk / turn him as one model; his shack is A4_ForemanShack.

    Animated NPC (owner R30): the figure is split into rig pieces (Torso*/Head*/ArmL*/ArmR*/LegL*/
    LegR*, see models/_npc_rig.py) so the client ManagerController can walk him, swing his limbs,
    wave (it raises the relaxed left arm) and tap his clipboard. The clipboard rides the right arm.
    """
    from models._npc_rig import a4_bones, rig_split

    m = Model("A4_Foreman", "feet centre; faces -Z", budget=2000)
    pieces = {
        "skin": m.piece("Skin", SKIN, material="Smooth"),
        "shirt": m.piece("Shirt", ORANGE, material="StudsSmall"),
        "pants": m.piece("Pants", DEEP_BLUE, material="StudsSmall"),
        "dark": m.piece("Dark", CHARCOAL, material="Smooth"),
        "hat": m.piece("Hat", WHITE, material="StudsSmall"),
        "accent": m.piece("Stripes", HAZARD_YELLOW, material="StudsSmall"),
        "board": m.piece("Clipboard", WOOD_DARK, material="StudsSmall"),
    }
    pieces["paper"] = pieces["hat"]
    xf = Xf((0.0, 0.0, 0.0))
    toy_figure(pieces, xf, hat="hardhat", right_arm="clipboard", vest=True)
    # Body-part pieces for the client NPC rig (the clipboard is held in the right hand). The torso
    # bone stops at the collar (y 4.0) so the neck + mouth bars classify with the head, not the torso.
    bones = a4_bones(xf, "down", "clipboard")
    bones["Torso"] = (bones["Torso"][0], xf.p(0.0, 4.0, 0.0))
    rig_split(m, bones, assign={"Clipboard": "ArmR"}, frame=((0.0, 0.0, 0.0), 0.0))
    return m


BUILDERS = {
    "A4_Floor": build_floor,
    "A4_EntryArch": build_entry_arch,
    "A4_CaveSideR": build_cave_side_r,
    "A4_CaveSideL": build_cave_side_l,
    "A4_CaveBack": build_cave_back,
    "A4_GlowDrill": build_glow_drill,
    "A4_BeamFrame": build_beam_frame,
    "A4_Miner": build_miner,
    "A4_CartTrack": build_cart_track,
    "A4_MineCart": build_mine_cart,
    "A4_DrillRig": build_drill_rig,
    "A4_CrystalLamp": build_crystal_lamp,
    "A4_GlowVein": build_glow_vein,
    "A4_ForemanShack": build_foreman_shack,
    "A4_Foreman": build_foreman,
}
