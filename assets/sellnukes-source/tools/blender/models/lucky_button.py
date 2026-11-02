"""
lucky_button.py — the R69 Lucky Button (docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §1).

Lucky_Button  a chunky toy ARCADE BUTTON that pops up on the player's own plot: a white studded
              housing (Base) with a coloured collar (Ring) around a big rounded push cap (Cap).
              Ring + Cap are tinted at runtime by kind (Client/LuckyButtons/LuckyButtonClient:
              green = free cash, gold = 2x Cash, blue = 2x Speed, purple = Robux deals), so ONE
              mesh set serves every kind. Pivot: ground centre; cap top at y = 2.15. ~4.8 studs
              wide: big enough to read from across the plot, small enough to sit between pads.

Pieces
    Base   white studded housing: a wide foot (flared), the drum and a lip the collar sits on
    Ring   tinted collar ring around the cap seat (square-section tube, catches the light)
    Cap    tinted push cap: a deep rounded dome-like disc (StudsSmall so it reads as a toy)

Budget: <= 1,200 triangles (at most a few are ever live per client; still a prop budget).
"""

from snkit.core import YELLOW, Model, WHITE
from snkit.kit import disc
from snkit.shapes import revolve, ring_tube


def build_lucky_button():
    """White studded arcade-button housing + tinted collar + tinted rounded push cap."""
    m = Model("Lucky_Button", "ground centre; cap top at y = 2.15; round (no facing)", budget=1200)
    base = m.piece("Base", WHITE, material="Studs")
    # Housing profile (radius, height): flared foot -> drum -> a small inward lip at the top that
    # the collar and the cap sit on. Closed so the bottom and the lip are capped (no see-through).
    revolve(
        base,
        [
            (0.0, 0.0),
            (2.4, 0.0),
            (2.45, 0.12),
            (2.2, 0.38),
            (2.05, 0.5),
            (2.05, 1.08),
            (1.95, 1.2),
            (1.7, 1.2),
            (0.0, 1.2),
        ],
        center=(0, 0, 0),
        segments=28,
    )
    ring = m.piece("Ring", YELLOW, material="Smooth", tinted=True)
    # Collar around the cap seat: centre radius 1.86, 0.36 wide, 0.34 deep, sitting on the lip.
    ring_tube(ring, (0, 1.36, 0), 1.86, 0.36, 0.34, segments=28)
    cap = m.piece("Cap", YELLOW, material="StudsSmall", tinted=True)
    # Push cap: a tall disc with a big bevel = a soft rounded toy button (top at 1.2 + 0.95).
    disc(cap, (0, 1.2, 0), 1.62, 0.95, segments=28, bevel=0.42)
    return m


BUILDERS = {
    "Lucky_Button": build_lucky_button,
}
