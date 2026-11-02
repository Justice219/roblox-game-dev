"""
eggs_moon.py — the two World 3 "Moon Base" eggs (spec
docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §2.5, owner R70):

    MoonEgg     Moon Egg    (`moon_egg`,  opens at Moon area 2)   candy-lilac moon shell with violet
                                                                  craters (pale floors), a big sunny
                                                                  crescent moon on the front and a
                                                                  sprinkle of tiny Neon stars
    CometEgg    Comet Egg   (`comet_egg`, opens at Moon area 5)   royal-blue shell with a glowing Neon
                                                                  comet head streaming cyan + pink
                                                                  trails around the egg, Neon star
                                                                  specks and cyan dots below

Both are built on eggs.py's cracked two-part shell (`build_shell`, `egg_frame`, the zig-zag crack at
CRACK_PHI), exactly like every area / Dino egg, so the R49 hatch cinematic and the generic
`EggShards` overlay fit them unchanged (HatchStage tints the flying chips with the piece named
`ShellTop`: lilac / royal blue):

    ShellTop*      upper shell + every decoration above the crack   (group "ShellTop", flies off)
    ShellBottom*   lower shell + every decoration below the crack   (group "ShellBottom", the cup)

Decorations hug the curved shell (eggs_dino._surface_decal: every outline point projected with
`egg_frame`), so nothing lifts off at the silhouette. `_check_crack_clear` fails the BUILD if any
ShellTop* / ShellBottom* decoration reaches the crack band, so the crack ribbons and the open
seam always land on clean shell.

Coordinates (Roblox space, like eggs.py): ORIGIN = ground point under the egg (bottom at y = 0);
the decorated face looks toward -Z (the stand's front); 3.0 studs tall, 2.3 wide. Pivot string
carries the hinge joint `joints ShellTop@(0,y,z)` (eggs._new_egg). Candy-vivid colours (owner R47 /
R70), judged with tools/blender/viewport_look.py.

Build / preview:
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only MoonEgg,CometEgg
    /opt/homebrew/bin/blender -b --python tools/blender/viewport_look.py -- OUT MoonEgg,CometEgg tools/blender/models/eggs_moon.py
"""

from __future__ import annotations

import math
import random

from snkit.core import br

from models._critter_kit import star_outline
from models.eggs import CRACK_AMP, CRACK_PHI, _new_egg, _shells, egg_point
from models.eggs_dino import _surface_blotch, _surface_decal
from models.pets_moon import _crescent

MOON_LILAC = (196, 170, 255)
CRATER_VIOLET = (138, 100, 240)
CRATER_FLOOR = (232, 216, 255)
CRESCENT_YELLOW = (255, 222, 56)
STAR_GLOW = (255, 246, 170)
COMET_BLUE = (64, 110, 255)
TRAIL_CYAN = (100, 232, 255)
TRAIL_PINK = (255, 104, 200)
COMET_HEAD = (255, 244, 150)
DOT_CYAN = (130, 236, 255)

# Height limits for decorations (studs): the crack zig-zag spans y ~1.18 .. 1.53 (eggs.CRACK_PHI
# +- CRACK_AMP); upper decorations stay above TOP_MIN, lower ones below BOTTOM_MAX (>= 0.09 studs
# clear of the outermost teeth), so nothing ever has to be split by the hatch.
TOP_MIN = egg_point(0, CRACK_PHI + CRACK_AMP).y + 0.09
BOTTOM_MAX = egg_point(0, CRACK_PHI - CRACK_AMP).y - 0.09


def _check_crack_clear(model) -> None:
    """
    Build-time guard: every ShellTop* decoration stays above TOP_MIN, every ShellBottom*
    decoration below BOTTOM_MAX (the shells themselves are exempt — they ARE the crack).
    Raises (fails the build) instead of shipping an egg whose decal would straddle the crack.
    """
    for name, piece in model.pieces.items():
        if name in ("ShellTop", "ShellBottom"):
            continue
        ys = [br(v.co)[1] for v in piece.bm.verts]
        if not ys:
            continue
        if name.startswith("ShellTop") and min(ys) < TOP_MIN:
            raise SystemExit(f"{model.key}.{name}: dips to y {min(ys):.2f} < {TOP_MIN:.2f} (crack band)")
        if name.startswith("ShellBottom") and max(ys) > BOTTOM_MAX:
            raise SystemExit(f"{model.key}.{name}: rises to y {max(ys):.2f} > {BOTTOM_MAX:.2f} (crack band)")


def _streak(length: float, width: float, steps: int = 6):
    """Tapered comet-trail outline: wide at the head (x = 0), a thin point at x = length."""
    upper = [(length * i / steps, width * (1 - i / steps) ** 0.8 + 0.012) for i in range(steps + 1)]
    lower = [(x, -y) for x, y in reversed(upper)]
    return upper + lower


def build_moon_egg():
    """Moon Egg (Moon area 2): lilac moon shell, violet craters, sunny crescent, tiny Neon stars."""
    m = _new_egg("MoonEgg", "Moon Egg (Moon Base area 2)")
    _shells(m, MOON_LILAC)
    rng = random.Random(7310)
    t_rim = m.piece("ShellTopCraters", CRATER_VIOLET, material="StudsSmall")
    b_rim = m.piece("ShellBottomCraters", CRATER_VIOLET, material="StudsSmall")
    t_floor = m.piece("ShellTopCraterFloor", CRATER_FLOOR, material="StudsSmall")
    b_floor = m.piece("ShellBottomCraterFloor", CRATER_FLOOR, material="StudsSmall")
    # A crater = a violet rim blotch + a raised pale floor inside it (reads as a dish, not a spot).
    for yaw, phi, r in ((62, 2.1, 0.3), (128, 2.4, 0.24), (175, 2.06, 0.28), (-112, 2.14, 0.3), (-52, 2.55, 0.2),
                        (-36, 2.02, 0.17), (220, 2.62, 0.17), (95, 2.78, 0.13)):
        _surface_blotch(t_rim, yaw, phi, r, rng, thick=0.04)
        _surface_blotch(t_floor, yaw, phi, r * 0.62, rng, sides=7, wobble=0.1, thick=0.06)
    for yaw, phi, r in ((22, 1.02, 0.3), (85, 0.72, 0.24), (-48, 1.0, 0.3), (-118, 0.74, 0.24), (150, 1.04, 0.28),
                        (205, 0.66, 0.2), (-15, 0.52, 0.16)):
        _surface_blotch(b_rim, yaw, phi, r, rng, thick=0.04)
        _surface_blotch(b_floor, yaw, phi, r * 0.62, rng, sides=7, wobble=0.1, thick=0.06)
    moon = m.piece("ShellTopMoon", CRESCENT_YELLOW, material="StudsSmall")
    _surface_decal(moon, _crescent(0.4), 8, 2.3, angle=-20, thick=0.07)
    stars = m.piece("ShellTopStars", STAR_GLOW, material="Neon")  # tiny accents (R19)
    for yaw, phi, s in ((35, 2.55, 0.07), (-30, 2.0, 0.06), (100, 2.45, 0.06), (-160, 2.4, 0.07), (230, 2.05, 0.06),
                        (10, 2.85, 0.05)):
        _surface_decal(stars, star_outline(s, s * 0.4, points=4), yaw, phi, thick=0.04)
    _check_crack_clear(m)
    return m


def build_comet_egg():
    """Comet Egg (Moon area 5): royal-blue shell, Neon comet head with cyan + pink trails, star specks."""
    m = _new_egg("CometEgg", "Comet Egg (Moon Base area 5)")
    _shells(m, COMET_BLUE)
    rng = random.Random(5521)
    head_yaw, head_phi = -38, 2.42
    head = m.piece("ShellTopComet", COMET_HEAD, material="Neon")  # the glowing comet head (~0.35 stud²)
    _surface_decal(head, star_outline(0.3, 0.15, points=5), head_yaw, head_phi, angle=-8, thick=0.07)
    cyan = m.piece("ShellTopTrail", TRAIL_CYAN, material="StudsSmall")
    pink = m.piece("ShellTopTrailPink", TRAIL_PINK, material="StudsSmall")
    # Trails stream from behind the head around the egg (+yaw), drooping slightly.
    _surface_decal(cyan, _streak(1.45, 0.15), head_yaw + 14, head_phi, angle=-12, thick=0.05)
    _surface_decal(cyan, _streak(1.0, 0.08), head_yaw + 12, head_phi - 0.16, angle=-16, thick=0.05)
    _surface_decal(pink, _streak(1.15, 0.09), head_yaw + 12, head_phi + 0.15, angle=-8, thick=0.05)
    specks = m.piece("ShellBottomStars", STAR_GLOW, material="Neon")
    for yaw, phi, s in ((20, 0.95, 0.07), (95, 0.7, 0.06), (-75, 1.05, 0.07), (160, 0.85, 0.06), (-150, 0.6, 0.05)):
        _surface_decal(specks, star_outline(s, s * 0.4, points=4), yaw, phi, thick=0.04)
    dots = m.piece("ShellBottomDots", DOT_CYAN, material="StudsSmall")
    for k in range(14):  # a loose ring of little cyan "planets" round the cup
        yaw = 360.0 * k / 14 + rng.uniform(-6, 6)
        phi = 1.06 + 0.07 * math.sin(k * 1.9)
        _surface_blotch(dots, yaw, phi, rng.uniform(0.05, 0.08), rng, sides=6, wobble=0.1, thick=0.04)
    for yaw, phi, s in ((150, 2.6, 0.07), (210, 2.2, 0.08), (90, 2.75, 0.06), (-120, 2.65, 0.06), (-100, 2.1, 0.07),
                        (120, 2.1, 0.07), (20, 2.85, 0.05)):
        _surface_decal(head, star_outline(s, s * 0.4, points=4), yaw, phi, thick=0.04)
    _check_crack_clear(m)
    return m


BUILDERS = {
    "MoonEgg": build_moon_egg,
    "CometEgg": build_comet_egg,
}
