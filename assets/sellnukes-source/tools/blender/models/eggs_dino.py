"""
eggs_dino.py — the two World 2 "Dino Valley" eggs (spec 2026-10-31-world2-design.md §8 / §16):

    DinoEgg      Dino Egg     (`dino_egg`,    opens at Dino area 2)   bright jungle-lime shell, sunny
                                                                       yellow spots, cream speckles, a
                                                                       cream cartoon BONE on top (the
                                                                       Bones currency) and a three-toed
                                                                       footprint on the front
    VolcanoEgg   Volcano Egg  (`volcano_egg`, opens at Dino area 5)   orange-red molten cobbles over a
                                                                       lava-yellow shell (the yellow
                                                                       "crackle" glows between them),
                                                                       a Neon lava cap dripping over the
                                                                       top and ember glints low down

Both are built on eggs.py's shell maths (`build_shell`, `egg_frame`, the zig-zag crack at
CRACK_PHI), so they are byte-for-byte the same cracked two-part SHELL as every area egg:

    ShellTop*      upper shell + every decoration above the crack   (group "ShellTop", flies off)
    ShellBottom*   lower shell + every decoration below the crack   (group "ShellBottom", the cup)

That makes them drop-in compatible with the R49 hatch cinematic: the generic `EggShards` overlay
(egg_shards.py: Shard1..7 chips + Crack1..3 / Crack1..3Glow ribbons) is built on the SAME
`egg_frame` / `crack_phi` surface, so its cracks sit on these shells and its stage-3 crack follows
their real seam. HatchStage tints the flying chips with the piece named exactly `ShellTop` (the
shell colour: jungle lime / crack yellow) unless EggConfig overrides it. Decorations stay inside
eggs.TOP_BAND / eggs.BOTTOM_BAND, so nothing crosses the crack and nothing has to be split.

Coordinates (Roblox space, like eggs.py): ORIGIN = ground point under the egg (bottom at y = 0);
the decorated face looks toward -Z (the nest stand's front); 3.0 studs tall, 2.3 wide.
Pivot string carries the hinge joint: `joints ShellTop@(0,y,z)` (eggs._new_egg).

Build / preview:
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only DinoEgg,VolcanoEgg
    python3 tools/blender/contact_sheet.py --only DinoEgg,VolcanoEgg
"""

from __future__ import annotations

import math
import random

from snkit.core import CREAM
from snkit.shapes import add_faces

from models._critter_kit import oriented_ellipsoid, tup
from models.eggs import BOTTOM_BAND, TOP_BAND, _new_egg, _shells, egg_frame

# Candy-vivid palette (owner R47 vividness pass; judged with tools/blender/viewport_look.py).
JUNGLE_LIME = (126, 228, 52)
SUNNY_SPOT = (255, 218, 52)
CRACK_YELLOW = (255, 204, 48)  # the shell itself: shows as glowing yellow cracks between the cobbles
MOLTEN_RED = (242, 82, 36)  # orange-red cobbles
LAVA_GLOW = (255, 142, 32)  # candy-orange lava cap: reads against the yellow cracks and red cobbles
EMBER_GLINT = (255, 232, 120)  # small pale-yellow glints on the red cobbles
PEBBLE_GLINT = (255, 252, 196)  # pale glowing pebble glints that read on the lime shell


def _blotch(radius, rng, sides=7, wobble=0.22):
    """Irregular blob outline: a `sides`-gon with seeded radius jitter (deterministic per seed)."""
    pts = []
    for k in range(sides):
        a = 2 * math.pi * (k + rng.uniform(-0.18, 0.18)) / sides
        r = radius * (1 + rng.uniform(-wobble, wobble))
        pts.append((r * math.cos(a), r * math.sin(a)))
    return pts


def _surface_decal(piece, outline, yaw0, phi0, angle=0.0, lift=0.0, thick=0.05):
    """
    A sticker that HUGS the shell: a 2-D outline [(x, y)] in studs (x = around the egg toward +yaw,
    y = up the meridian; rotated by `angle` degrees) centred on (yaw0 deg, phi0), converted to
    surface coordinates with the local arc lengths (meridian + latitude circle), every point
    projected with eggs.egg_frame and extruded along the local normals (outer cap at lift + thick,
    inner cap just under the skin). Unlike a flat decal plate (eggs._plate_on) it follows the curvature,
    so long decals (the bone) and spots on the silhouette never lift off or stick out.
    Closed prism; concave simple outlines are fine (Blender polyfills the caps).
    """
    a, _ = egg_frame(yaw0, phi0 - 0.01)
    b, _ = egg_frame(yaw0, phi0 + 0.01)
    per_phi = (b - a).length / 0.02  # studs per radian along the meridian
    centre, _ = egg_frame(yaw0, phi0)
    ring = max(math.hypot(centre.x, centre.z), 0.05)  # latitude circle radius (studs)
    ca, sa = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    outer, inner = [], []
    for x, y in outline:
        u, v = x * ca - y * sa, x * sa + y * ca
        q, nq = egg_frame(yaw0 + math.degrees(u / ring), phi0 + v / per_phi)
        outer.append(tup(q + nq * (lift + thick)))
        inner.append(tup(q - nq * 0.015))
    count = len(outline)
    faces = [tuple(range(count)), tuple(range(2 * count - 1, count - 1, -1))]
    for i in range(count):
        j = (i + 1) % count
        faces.append((i, count + i, count + j, j))
    add_faces(piece, outer + inner, faces)


def _surface_blotch(piece, yaw0, phi0, radius, rng, sides=7, wobble=0.2, thick=0.05):
    """A jittered round spot of `radius` studs hugging the shell (see _surface_decal)."""
    _surface_decal(piece, _blotch(radius, rng, sides=sides, wobble=wobble), yaw0, phi0, thick=thick)


def _bone_outline(length, width):
    """
    Chunky cartoon dog-bone silhouette (the Bones currency): a straight shaft between two
    double-lobed knuckles at each end, as ONE simple polygon (x along the bone, y across).
    """
    half, w = length / 2, width / 2
    knob = w * 1.05
    pts = []
    # Right end: two lobes (top + bottom) round the end cap, traced counter-clockwise.
    for cy, start, end in ((-w * 0.95, -110, 70), (w * 0.95, -70, 110)):
        for k in range(5):
            a = math.radians(start + (end - start) * k / 4)
            pts.append((half + knob * math.cos(a) * 0.9, cy + knob * math.sin(a)))
    pts.append((half - knob * 0.6, w * 0.62))
    pts.append((-half + knob * 0.6, w * 0.62))
    for cy, start, end in ((w * 0.95, 70, 250), (-w * 0.95, 110, 290)):
        for k in range(5):
            a = math.radians(start + (end - start) * k / 4)
            pts.append((-half + knob * math.cos(a) * 0.9, cy + knob * math.sin(a)))
    pts.append((-half + knob * 0.6, -w * 0.62))
    pts.append((half - knob * 0.6, -w * 0.62))
    return pts


def _footprint(piece, yaw, phi, size):
    """Three-toed cartoon dino footprint (round pad + three oval toes) stuck on the shell."""
    p, n = egg_frame(yaw, phi)
    oriented_ellipsoid(piece, tup(p + n * 0.01), (size * 0.42, size * 0.36, 0.05), normal=tup(n), rings=3, segments=10)
    for k, ang in enumerate((-34, 0, 34)):
        q, nq = egg_frame(yaw + ang * size * 0.55, phi + size * (0.62 if k == 1 else 0.5))
        up = (math.sin(math.radians(ang)), math.cos(math.radians(ang)), 0)
        oriented_ellipsoid(piece, tup(q + nq * 0.01), (size * 0.15, size * 0.24, 0.045), normal=tup(nq), up=up, rings=3, segments=8)


def build_dino_egg():
    """Dino Egg (Dino area 2): jungle-lime shell, sunny-yellow spots, cream bone + footprint, glints."""
    m = _new_egg("DinoEgg", "Dino Egg (Dino Valley area 2)")
    _shells(m, JUNGLE_LIME)
    rng = random.Random(4721)
    t_spots = m.piece("ShellTopSpots", SUNNY_SPOT, material="StudsSmall")
    b_spots = m.piece("ShellBottomSpots", SUNNY_SPOT, material="StudsSmall")
    for yaw, phi, r in ((48, 2.06, 0.2), (112, 2.3, 0.24), (170, 2.02, 0.22), (-130, 2.25, 0.2), (-62, 2.08, 0.18),
                        (75, 2.62, 0.16), (-160, 2.66, 0.15), (205, 2.45, 0.13), (-25, 2.6, 0.13)):
        _surface_blotch(t_spots, yaw, phi, r, rng)
    for yaw, phi, r in ((62, 1.08, 0.22), (128, 0.82, 0.24), (-70, 1.0, 0.22), (-140, 1.12, 0.2), (180, 0.65, 0.18),
                        (95, 0.45, 0.15), (-35, 0.5, 0.14)):
        _surface_blotch(b_spots, yaw, phi, r, rng)
    t_cream = m.piece("ShellTopSpeckles", CREAM, material="StudsSmall")
    b_cream = m.piece("ShellBottomSpeckles", CREAM, material="StudsSmall")
    # The cream cartoon bone on the top front (Bones = Dino Valley's currency).
    _surface_decal(t_cream, _bone_outline(0.9, 0.24), 0, 2.22, angle=18, thick=0.06)
    for yaw, phi, r in ((32, 2.55, 0.06), (88, 1.95, 0.07), (140, 2.5, 0.06), (-100, 1.98, 0.07), (-150, 2.48, 0.05),
                        (-45, 2.85, 0.05), (150, 2.85, 0.05), (230, 2.1, 0.06), (60, 2.95, 0.045)):
        _surface_blotch(t_cream, yaw, phi, r, rng, sides=6, wobble=0.12, thick=0.035)
    _footprint(b_cream, 0, 0.98, 0.5)
    for yaw, phi, r in ((40, 0.75, 0.06), (100, 1.2, 0.07), (160, 1.05, 0.06), (-110, 0.75, 0.07), (-60, 1.25, 0.05),
                        (-170, 0.9, 0.06), (210, 0.4, 0.05)):
        _surface_blotch(b_cream, yaw, phi, r, rng, sides=6, wobble=0.12, thick=0.035)
    glow = m.piece("ShellTopGlow", PEBBLE_GLINT, material="Neon")  # a few glowing pebble glints (R19: tiny)
    for yaw, phi, r in ((-20, 2.0, 0.055), (125, 2.12, 0.05), (-115, 2.6, 0.045), (35, 2.4, 0.045)):
        _surface_blotch(glow, yaw, phi, r, rng, sides=6, wobble=0.1, thick=0.04)
    return m


def _tile_rows(rows, rng):
    """
    Cobble tile layout for the Volcano Egg: rows of (phi, count); each row's tiles are evenly
    spaced in yaw with a seeded jitter and a half-step stagger on odd rows, so the thin orange
    seams between tiles read as a random lava crackle. Deterministic (same seed, same egg).
    Returns [(yaw_deg, phi, half_width_deg)].
    """
    cells = []
    for row, (phi, count) in enumerate(rows):
        step = 360.0 / count
        offset = step * (0.5 if row % 2 else 0.0) + rng.uniform(0, step)
        for k in range(count):
            cells.append((offset + step * k + rng.uniform(-step * 0.06, step * 0.06), phi, step * 0.5))
    return cells


def _curved_tile(piece, yaw0, phi0, half_w, half_h, rng, fill=0.87, lift=0.0, thick=0.05):
    """
    One molten cobble that HUGS the shell: a jittered six-corner brick (a rectangle with a
    mid-point on its long top / bottom edges, so it bends with the egg) laid out in
    (yaw deg, phi) surface coordinates, every corner projected onto the egg skin with
    eggs.egg_frame, then extruded along the local normals (outer cap at lift + thick, inner cap
    just under the skin). Unlike a flat decal plate it follows the curvature, so cobbles never
    jut out at the silhouette and can sit close together: `fill` = 0.87 leaves a thin yellow
    crackle seam (~13 % of a cobble) between neighbours.
    Closed prism (outer + inner caps + walls): 20 triangles; snkit recomputes outward normals.
    """
    corners = ((-1.0, -1.0), (-1.0, 1.0), (0.0, 1.0), (1.0, 1.0), (1.0, -1.0), (0.0, -1.0))
    outer, inner = [], []
    for cx, cy in corners:
        yaw = yaw0 + (cx + rng.uniform(-0.08, 0.08)) * half_w * fill
        phi = phi0 + (cy + rng.uniform(-0.08, 0.08)) * half_h * fill
        q, nq = egg_frame(yaw, phi)
        outer.append(tup(q + nq * (lift + thick)))
        inner.append(tup(q - nq * 0.015))
    k = len(corners)
    faces = [tuple(range(k)), tuple(range(2 * k - 1, k - 1, -1))]
    for i in range(k):
        j = (i + 1) % k
        faces.append((i, k + i, k + j, j))
    add_faces(piece, outer + inner, faces)


def _lava_cap(piece, edge_phi, columns=36, rings=3, lift=0.035, thick=0.06):
    """
    Candy-lava "icing" poured over the top pole: a closed, shell-hugging solid from the pole down
    to a wavy lower edge `edge_phi(yaw_deg)` (rounded drips where the edge dips). Every vertex is
    an egg_frame point pushed out along the normal: inner skin at `lift` (just under the cobble
    tops, so cobbles hide inside it), outer skin at lift + thick, joined by a rim along the edge.
    Same ring construction as eggs.build_shell (the pole ring collapses into a fan on weld).
    """
    outer, inner = [], []
    for k in range(rings + 1):
        for c in range(columns):
            yaw = 360.0 * c / columns
            phi = math.pi - (math.pi - edge_phi(yaw)) * (k / rings)
            q, nq = egg_frame(yaw, phi)
            outer.append(tup(q + nq * (lift + thick)))
            inner.append(tup(q + nq * lift))
    off = len(outer)
    faces = []
    for k in range(rings):
        for c in range(columns):
            c2 = (c + 1) % columns
            a, b = k * columns + c, k * columns + c2
            d, e = (k + 1) * columns + c2, (k + 1) * columns + c
            faces.append((a, b, d, e))
            faces.append((off + e, off + d, off + b, off + a))
    last = rings * columns
    for c in range(columns):
        c2 = (c + 1) % columns
        faces.append((last + c2, last + c, off + last + c, off + last + c2))
    add_faces(piece, outer + inner, faces)


def build_volcano_egg():
    """Volcano Egg (Dino area 5): orange-red cobbles over yellow glowing cracks, Neon lava cap + drips."""
    m = _new_egg("VolcanoEgg", "Volcano Egg (Dino Valley area 5)")
    _shells(m, CRACK_YELLOW)
    rng = random.Random(9133)
    t_rock = m.piece("ShellTopRock", MOLTEN_RED, material="StudsSmall")
    b_rock = m.piece("ShellBottomRock", MOLTEN_RED, material="StudsSmall")
    # Cobble rows (phi centre, cobbles per row), `row` = the phi pitch between rows. A cobble
    # spans phi +- row/2 * fill * 1.08 at most, so the top row ends above eggs.TOP_BAND[0] and the
    # lowest row's top edge stays under eggs.BOTTOM_BAND[1]: nothing reaches the zig-zag crack, so
    # the EggShards crack ribbons and the open seam stay rock-free (asserted below). The bare
    # yellow belt left around the crack reads as the egg's hot glowing seam.
    row = 0.27
    top_rows = ((1.99, 11), (2.26, 9))
    bottom_rows = ((1.25, 12), (0.98, 10), (0.71, 8), (0.44, 5))
    reach = row / 2 * 0.87 * 1.08
    assert top_rows[0][0] - reach >= TOP_BAND[0] and bottom_rows[0][0] + reach <= BOTTOM_BAND[1]
    top_cells = _tile_rows(top_rows, rng)
    bottom_cells = _tile_rows(bottom_rows, rng)
    for yaw, phi, half_w in top_cells:
        _curved_tile(t_rock, yaw, phi, half_w, row / 2, rng)
    for yaw, phi, half_w in bottom_cells:
        _curved_tile(b_rock, yaw, phi, half_w, row / 2, rng)
    lava = m.piece("ShellTopLava", LAVA_GLOW, material="Neon")
    # Lava cap: base edge at phi 2.44 with 7 seeded rounded drips (gaussian dips) flowing down
    # over the second cobble row. One Neon piece whose largest box face (~1.6 x 1.6 studs) stays
    # well under the R19 6 stud² Neon cap.
    drips = [(360.0 * k / 7 + rng.uniform(-14, 14), rng.uniform(0.1, 0.24)) for k in range(7)]

    def edge(yaw):
        dip = 0.0
        for centre, depth in drips:
            delta = (yaw - centre + 180.0) % 360.0 - 180.0
            dip = max(dip, depth * math.exp(-((delta / 8.5) ** 2)))
        return 2.44 - dip

    _lava_cap(lava, edge)
    embers = m.piece("ShellBottomGlow", EMBER_GLINT, material="Neon")
    # Ember glints seated on the centres of a few front-facing cobbles (small Neon accents, R19).
    picks = [c for c in bottom_cells if math.cos(math.radians(c[0])) > -0.2][::3]
    for yaw, phi, _ in picks[:7]:
        _surface_decal(embers, _blotch(0.07, rng, sides=6, wobble=0.25), yaw, phi, lift=0.045, thick=0.03)
    return m


BUILDERS = {
    "DinoEgg": build_dino_egg,
    "VolcanoEgg": build_volcano_egg,
}
