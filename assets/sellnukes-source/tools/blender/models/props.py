"""
props.py — shared props used across every area.

BuyPad      chunky tyre-ring buy pad with a raised coloured button top (reference: sell-lemons
            11-fence-buy-button.png). The `Top` piece is tinted: PadKind colour is set at spawn
            (MeshLibrary.spawn(..., {tint = colour})). Pivot: ground centre.
PocketNuke  the cartoon "pocket nuke" product: chubby candy body (tinted per tier), white nose,
            dark fins, glowing green core band and a yellow radiation badge on the front (-Z).
            Pivot: centre under the fins, nose up (+Y). ~3 studs tall: sits on the workbench, rides
            conveyors, pops out of crates.

Budgets: props <= 1,500 triangles (hundreds are on screen at once).
"""

from snkit.core import (
    CHARCOAL,
    DARK_STEEL,
    GLOW_GREEN,
    GRASS,
    HAZARD_BLACK,
    HAZARD_YELLOW,
    Model,
    TOY_RED,
    TYRE,
    WHITE,
)
from snkit.kit import disc, nuke_body, trefoil, tyre_ring
from snkit.shapes import revolve


def build_buy_pad():
    """Tyre (dark, lugged) + steel rim + big rounded button on top (tinted)."""
    m = Model("BuyPad", "ground centre of the pad; button top at y = 1.55", budget=1500)
    tyre = m.piece("Tyre", TYRE)
    tyre_ring(tyre, (0, 0, 0), 2.35, 3.45, 1.15, lugs=14, segments=28)
    rim = m.piece("Rim", DARK_STEEL)
    # Inner steel rim the button sits in (hides the tyre's inner wall, reads like a wheel hub).
    revolve(
        rim,
        [(2.0, 0.15), (2.42, 0.15), (2.42, 1.22), (2.0, 1.22)],
        center=(0, 0, 0),
        segments=28,
        closed=True,
    )
    top = m.piece("Top", GRASS, tinted=True)
    disc(top, (0, 0.5, 0), 2.3, 1.05, segments=28, bevel=0.28)
    return m


def build_pocket_nuke():
    """Cartoon nuke ~3 studs tall: tinted body, white nose + trim, dark fins, neon core, badge."""
    m = Model("PocketNuke", "centre under the fins; nose up (+Y); badge faces -Z", budget=1500)
    body = m.piece("Body", TOY_RED, material="StudsSmall", tinted=True)
    nose = m.piece("Nose", WHITE, material="StudsSmall")
    fins = m.piece("Fins", CHARCOAL, material="StudsSmall")
    core = m.piece("Core", GLOW_GREEN, material="Neon")
    radius = 0.72
    core_y = nuke_body(body, nose, fins, core, base=(0, 0, 0), length=3.1, radius=radius, segments=16)
    # Yellow badge disc on the front (-Z) above the core band, with a black trefoil.
    badge = m.piece("Badge", HAZARD_YELLOW, material="Smooth")
    mark = m.piece("Trefoil", HAZARD_BLACK, material="Smooth")
    badge_y = core_y + 0.52
    revolve(
        badge,
        [(0.0, -0.06), (0.34, -0.06), (0.38, 0.0), (0.34, 0.06), (0.0, 0.06)],
        center=(0, badge_y, -radius + 0.02),
        segments=16,
        rot=_face_front(),
    )
    trefoil(mark, (0, badge_y, -radius - 0.06), 0.3, 0.05, normal=(0, 0, -1))
    return m


def _face_front():
    """Rotation that turns a Y-axis revolve into a disc facing -Z (badge on the nuke's front)."""
    from snkit.shapes import rot_x

    return rot_x(90)


BUILDERS = {"BuyPad": build_buy_pad, "PocketNuke": build_pocket_nuke}
