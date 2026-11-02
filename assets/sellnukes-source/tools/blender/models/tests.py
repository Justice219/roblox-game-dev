"""
tests.py — models used only for pipeline experiments (built only when named with --only).

StudTest: a 4 x 4 x 4 chamfered cube ("Cube") and a 3-wide, 4-tall cylinder ("Cyl") with the
standard world-scale cube-projected UVs. Used in Studio next to primitive Parts of the same size
to compare stud density/orientation between MeshParts and Parts (docs/world-art.md, experiment).
"""

from snkit.core import Model, WHITE
from snkit.kit import block
from snkit.shapes import cylinder


def build_stud_test():
    """Pivot: ground centre between the two shapes; cube at x = -3, cylinder at x = +3."""
    m = Model("StudTest", "ground centre; cube at x=-3, cylinder at x=+3", budget=400)
    block(m.piece("Cube", WHITE), (-3, 2, 0), (4, 4, 4), bevel=0.15)
    cylinder(m.piece("Cyl", WHITE), (3, 0, 0), (3, 4, 0), 1.5, segments=20)
    return m


def build_stud_test_uv2():
    """Same shapes as StudTest but "StudsSmall" (UVs at 2x density): proves whether MeshPart
    material mapping follows mesh UVs (studs halve) or ignores them (studs unchanged)."""
    m = Model("StudTestUV2", "ground centre; cube at x=-3, cylinder at x=+3", budget=400)
    block(m.piece("Cube", WHITE, material="StudsSmall"), (-3, 2, 0), (4, 4, 4), bevel=0.15)
    cylinder(m.piece("Cyl", WHITE, material="StudsSmall"), (3, 0, 0), (3, 4, 0), 1.5, segments=20)
    return m


BUILDERS = {"StudTest": build_stud_test, "StudTestUV2": build_stud_test_uv2}
