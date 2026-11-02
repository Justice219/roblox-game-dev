"""
kinetic.py — owner R90 hands-on plot props (docs/superpowers/specs/2026-10-31-r90-hands-on-design.md
§2 Mega Lever, §3 Tip Jar; system doc docs/kinetic.md). Built by K-kinetic.

Kinetic_Lever  a giant candy-striped toy lever machine in Area 1's front yard inside the plot
               (owner R116; Shared/Config/KineticConfig.Placement.Lever, slot-local). Front (-Z)
               faces the road; the chute runs toward -X (along the yard) and ends in a catch tray.
               Pivot: ground centre of the plinth.
               Animated pieces (Client/Kinetic/KineticVisuals swings them about the hinge axle,
               KineticConfig.Lever.Hinge = (3.2, 3.6, 0.2), axis +X):
                   Arm, ArmStripes  the candy-striped arm (white bands + red bands + the red knob),
                                    authored at the REST pose: tilted 30 degrees back (toward +Z)
               HopperNuke is the toy nuke resting in the hopper; the client CLONES it for the Mega
               Batch ride down the chute (one MeshPart, recoloured per flavour), so the FX reuses an
               already-loaded mesh instead of creating new geometry.

Kinetic_TipJar a glass tip jar on a little wooden crate (KineticConfig.Placement.Jar). The Coins
               piece is the gold pile at FULL height; the client scales it with the jar's Fill
               attribute (bottom fixed at y = 1.45). Glass is transparent (Glass material, 0.55).
               Pivot: ground centre of the crate.

Pieces stay <= 12 per model (one colour = one MeshPart = one draw call). Budgets are prop budgets
(one of each per plot, at most 8 + 8 per world).
"""

import math

from snkit.core import (
    DARK_STEEL,
    GLASS,
    GLOW_GREEN,
    Model,
    TOY_RED,
    WHITE,
    WOOD,
    WOOD_DARK,
    YELLOW,
)
from snkit.kit import block, disc
from snkit.shapes import bar, box, cylinder, ellipsoid, revolve, ring_tube, rot_z

# Coin gold (a touch warmer than YELLOW so the pile reads as money through the glass).
GOLD = (255, 196, 40)

# Lever geometry shared with KineticConfig.Lever (keep in sync; tests/kinetic-logic.luau reads the
# config, the manifest pins the pieces).
HINGE = (3.2, 3.6, 0.2)  # arm pivot (model space)
ARM_LENGTH = 5.2
ARM_RADIUS = 0.32
REST_TILT = 30.0  # degrees back toward +Z from vertical
ARM_BANDS = 8

# Chute: from the housing's -X face down to the catch tray (model space, slope toward -X).
CHUTE_TOP = (-1.9, 4.5, 0.2)
CHUTE_END = (-9.0, 0.95, 0.2)


def _arm_point(distance: float) -> tuple:
    """A point `distance` studs up the arm from the hinge, at the rest tilt."""
    tilt = math.radians(REST_TILT)
    return (
        HINGE[0],
        HINGE[1] + math.cos(tilt) * distance,
        HINGE[2] + math.sin(tilt) * distance,
    )


def build_lever():
    """Candy-striped toy lever machine: plinth, red housing, hopper + nuke, chute, striped arm."""
    m = Model(
        "Kinetic_Lever",
        "ground centre of the plinth; front faces -Z; chute toward -X; arm hinge (3.2, 3.6, 0.2)",
        budget=3000,
    )
    base = m.piece("Base", WHITE, material="Studs")
    housing = m.piece("Housing", TOY_RED, material="Studs")
    trim = m.piece("Trim", YELLOW, material="StudsSmall")
    face = m.piece("Face", WHITE, material="Smooth")
    bulbs = m.piece("Bulbs", YELLOW, material="Neon")
    steel = m.piece("Steel", DARK_STEEL, material="Smooth")
    arm = m.piece("Arm", WHITE, material="Smooth")
    stripes = m.piece("ArmStripes", TOY_RED, material="Smooth")
    hopper = m.piece("Hopper", YELLOW, material="Studs")
    nuke = m.piece("HopperNuke", GLOW_GREEN, material="Smooth")
    chute = m.piece("Chute", YELLOW, material="Smooth")

    # Plinth (walkable-looking studded slab) under the whole machine.
    block(base, (0.0, 0.6, 0.0), (7.0, 1.2, 6.4), bevel=0.2)
    # Housing: a chunky red machine box with yellow bands top + bottom.
    block(housing, (0.4, 3.0, 0.2), (4.6, 3.6, 4.4), bevel=0.25)
    block(trim, (0.4, 4.95, 0.2), (4.9, 0.3, 4.7), bevel=0.08)
    block(trim, (0.4, 1.35, 0.2), (4.9, 0.3, 4.7), bevel=0.08)
    # Front plate with a row of glowing bulbs (reads as "machine" from the entrance).
    block(face, (0.4, 3.0, -2.06), (3.4, 2.1, 0.16), bevel=0.05)
    for i in range(4):
        x = -0.65 + i * 0.7
        ellipsoid(bulbs, (x, 3.75, -2.2), (0.24, 0.24, 0.16), rings=5, segments=8)
    # A big green "GO" button under the bulbs (decoration: the lever is what you pull).
    ellipsoid(bulbs, (0.4, 2.55, -2.18), (0.55, 0.55, 0.14), rings=5, segments=10)

    # Hinge axle out of the housing's +X face + a hub disc the arm sits in.
    cylinder(steel, (2.7, HINGE[1], HINGE[2]), (3.65, HINGE[1], HINGE[2]), 0.55, segments=14)
    cylinder(steel, (3.65, HINGE[1], HINGE[2]), (3.8, HINGE[1], HINGE[2]), 0.75, segments=14)

    # Candy-striped arm: alternating white / red bands from the hinge, red knob on top.
    band = ARM_LENGTH / ARM_BANDS
    for i in range(ARM_BANDS):
        target = arm if i % 2 == 0 else stripes
        cylinder(target, _arm_point(i * band), _arm_point((i + 1) * band), ARM_RADIUS, segments=12)
    ellipsoid(stripes, _arm_point(ARM_LENGTH + 0.55), (0.78, 0.78, 0.78), rings=8, segments=12)

    # Hopper (a funnel cup) on top of the housing, with the toy nuke peeking out of it.
    cylinder(hopper, (-0.6, 4.8, 0.2), (-0.6, 5.9, 0.2), 0.7, segments=16, radius_b=1.4)
    cylinder(nuke, (-0.6, 5.3, 0.2), (-0.6, 6.45, 0.2), 0.42, segments=12)
    ellipsoid(nuke, (-0.6, 6.55, 0.2), (0.42, 0.55, 0.42), rings=6, segments=12)
    for k in range(3):
        angle = math.radians(k * 120.0)
        dx, dz = math.cos(angle) * 0.55, math.sin(angle) * 0.55
        bar(nuke, (-0.6 + dx * 0.6, 5.35, 0.2 + dz * 0.6), (-0.6 + dx, 5.6, 0.2 + dz), 0.12)

    # Chute: a sloped trough (bottom plate + two rails) from the housing down to a catch tray.
    dx = CHUTE_END[0] - CHUTE_TOP[0]
    dy = CHUTE_END[1] - CHUTE_TOP[1]
    length = math.sqrt(dx * dx + dy * dy)
    slope = math.degrees(math.atan2(-dy, -dx))  # rises toward +X
    mid = ((CHUTE_TOP[0] + CHUTE_END[0]) / 2, (CHUTE_TOP[1] + CHUTE_END[1]) / 2, CHUTE_TOP[2])
    box(chute, mid, (length, 0.2, 1.7), rot=rot_z(slope), bevel=0.04)
    for side in (-1, 1):
        rail = (mid[0], mid[1] + 0.28, mid[2] + side * 0.82)
        box(chute, rail, (length, 0.55, 0.14), rot=rot_z(slope), bevel=0.03)
    # Catch tray at the chute's end (the nukes "arrive" here, confetti pops).
    block(chute, (CHUTE_END[0] - 0.4, 0.45, CHUTE_END[2]), (1.8, 0.9, 2.2), bevel=0.1)
    # Two steel legs under the chute.
    for t in (0.35, 0.7):
        x = CHUTE_TOP[0] + dx * t
        y = CHUTE_TOP[1] + dy * t - 0.15
        bar(steel, (x, 0.0, CHUTE_TOP[2]), (x, y, CHUTE_TOP[2]), 0.22)
    return m


def build_tip_jar():
    """Glass tip jar on a wooden crate; the gold Coins pile is authored full (client scales it)."""
    m = Model("Kinetic_TipJar", "ground centre of the crate; front faces -Z; coin pile bottom y = 1.45", budget=2000)
    crate = m.piece("Base", WOOD, material="Studs")
    slats = m.piece("Slats", WOOD_DARK, material="StudsSmall")
    glass = m.piece("Glass", GLASS, material="Glass", transparency=0.55)
    rim = m.piece("Rim", YELLOW, material="Smooth")
    coins = m.piece("Coins", GOLD, material="StudsSmall")
    emblem = m.piece("Emblem", YELLOW, material="Neon")

    # Crate + darker slats on the four faces.
    block(crate, (0.0, 0.7, 0.0), (4.0, 1.4, 4.0), bevel=0.15)
    for side in (-1, 1):
        block(slats, (0.0, 0.7, side * 2.02), (4.1, 0.3, 0.12), bevel=0.03)
        block(slats, (side * 2.02, 0.7, 0.0), (0.12, 0.3, 4.1), bevel=0.03)
    # Glass jar: an open band of revolution (wide belly, rounded shoulder, neck).
    revolve(
        glass,
        [
            (1.4, 1.4),
            (1.6, 1.5),
            (1.68, 1.8),
            (1.68, 4.05),
            (1.55, 4.4),
            (1.3, 4.62),
            (1.22, 4.8),
        ],
        center=(0, 0, 0),
        segments=20,
    )
    # Glass floor (so the pile never looks like it floats over the crate).
    disc(glass, (0.0, 1.4, 0.0), 1.42, 0.06, segments=20, bevel=0.0)
    # Yellow lip ring at the neck.
    ring_tube(rim, (0.0, 4.86, 0.0), 1.25, 0.32, 0.26, segments=20)
    # Gold coin pile at FULL height (1.45 .. 4.35) with a soft domed top.
    revolve(
        coins,
        [(0.0, 1.45), (1.5, 1.45), (1.55, 1.6), (1.55, 3.9), (1.2, 4.2), (0.6, 4.35), (0.0, 4.38)],
        center=(0, 0, 0),
        segments=18,
    )
    # Glowing coin emblem on the crate front (reads as "tips" from across the plot).
    ellipsoid(emblem, (0.0, 0.75, -2.1), (0.55, 0.55, 0.1), rings=5, segments=12)
    return m


BUILDERS = {
    "Kinetic_Lever": build_lever,
    "Kinetic_TipJar": build_tip_jar,
}
