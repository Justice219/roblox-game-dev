"""
pets.py — the SellNukes pet roster: chunky, glossy, radioactive-cute toy critters (spec §8).

Pets follow their owner (client-animated, server-owned inventory). Every pet is ONE Blender model
of <= 10 single-colour pieces (<= 10 draw calls; 8 players x 3-5 equipped pets are on screen) and
<= 2,800 triangles. Bodies use the `StudsSmall` stud material (0.5-stud cells read as a LEGO toy at
pet scale); faces/eyes are `Smooth`; glowing bits are `Neon`; slime / jelly / helmet bubbles are
`Glass` (translucent, the Neon core shows through).

Coordinates (Roblox space, studs):
    ORIGIN = the pet's GROUND-CONTACT CENTRE: the ground point under the middle of the pet. Every pet
    is modelled resting on y = 0 (feet / belly / tentacle tips touch y = 0); floaters get their
    flying height from `hover` (the runtime lifts the whole model by it and bobs around it).
    The pet FACES -Z; +X is the pet's right-hand side. Pets are ~1.8-2.6 studs tall (an R15 avatar
    is ~5), so they reach about the owner's hip.

ANIMATION CONTRACT (piece name prefix = animation group; the pivot string carries every joint):
    Body*   (no prefix below)  rigid root: welded to the pet root (bob / squash / tilt the whole pet)
    Head*   Head, HeadFace, HeadShine, HeadAccent, HeadEars, HeadHorn, ...  -> one joint "Head"
            (nod / tilt about the neck point)
    Tail*   Tail, TailTip, TailB, TailGlow                              -> joint "Tail" (wag)
    WingL* / WingR*   wings, flippers                                   -> joints "WingL" / "WingR" (flap)
    ClawL* / ClawR*   crab claws                                        -> joints "ClawL" / "ClawR" (snip)
    Orbit*  Neon atom rings around the pet                              -> joint "Orbit" (spin about +Y)
    Glow / Core / Face / Shine / Belly / ... (anything else)            -> Body group (Glow pieces are
            Neon: the runtime may pulse their Color/Transparency but never moves them)
    Joints are written as `joints Head@(x,y,z) Tail@(x,y,z) ...` in MeshAssets[key].pivot, e.g.
        "ground-contact centre ...; rarity Rare; hover 0; joints Head@(0,1.02,-0.24) Tail@(0,0.86,0.78)"
    Rotate a group's pieces about its joint point (model space) — every animated piece is buried in
    its host at the joint so small rotations never open a gap.

RARITY FLAIR (visible at a glance, cheap):
    Common       plain toy + one small Neon detail (badge / core)
    Uncommon     + Neon spots / a glowing held item
    Rare         + one Neon atom orbit ring (Orbit) with an electron
    Epic         + two orbit rings or a signature glowing feature (helmet, horn, gills)
    Legendary    + gold accents (antlers, crown, crest), two rings
    Mythic       + gold horns / halo ring, glowing wings / horn, translucent or neon body parts
    Secret       all-gold or void-black body, glowing eyes, crown + double ring
    Group        BuilderBeaver (group-exclusive reward)
    Event        GobbleBomb (Harvest Feast sticker-sheet reward), Harvest Egg pets

Roster (key — display name — intended rarity — hover):
    GlowSlime        Glow Slime          Common      0      AtomPup          Atom Pup          Common     0
    IsotopeKitty     Isotope Kitty       Common      0      QuarkDuck        Quark Duck        Common     0
    UraniumBunny     Uranium Bunny       Uncommon    0      NeutronNewt      Neutron Newt      Uncommon   0
    PlasmaPig        Plasma Pig          Uncommon    0      MegaMole         Mega Mole         Uncommon   0
    FissionFox       Fission Fox         Rare        0      ReactorOwl       Reactor Owl       Rare       0.8
    ProtonPanda      Proton Panda        Rare        0      GammaGator       Gamma Gator       Rare       0
    NuclearNarwhal   Nuclear Narwhal     Epic        1.0    CosmicCorgi      Cosmic Corgi      Epic       0
    RadRaccoon       Rad Raccoon         Epic        0      AtomicAxolotl    Atomic Axolotl    Epic       0.4
    MeltdownMoose    Meltdown Moose      Legendary   0      FusionPhoenix    Fusion Phoenix    Legendary  1.0
    ReactorRex       Reactor Rex         Legendary   0      CoreDragon       Core Dragon       Mythic     0.9
    NovaUnicorn      Nova Unicorn        Mythic      0      IonJelly         Ion Jelly         Mythic     1.0
    GoldenNukey      Golden Nukey        Secret      0      VoidCat          Void Cat          Secret     0.3
    BuilderBeaver    Builder Beaver      Group       0      GobbleBomb       Gobble Bomb       Event      0
    AcornSquirrel    Acorn Squirrel      Harvest C   0      HarvestHedgehog  Harvest Hedgehog  Harvest R  0
    CranberryCrab    Cranberry Crab      Harvest E   0
Full catalogue (pieces, colours, joints, hover): docs/pets-art.md.

Build / preview:
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only GlowSlime,AtomPup
    python3 tools/blender/contact_sheet.py --only GlowSlime,AtomPup
"""

from __future__ import annotations

import math

from mathutils import Vector

from snkit.core import (
    CREAM,
    GLASS,
    GLOW_GREEN,
    HAZARD_YELLOW,
    LEAF,
    LIME,
    MINT,
    Model,
    ORANGE,
    PINK,
    PURPLE,
    TOY_RED,
    WOOD_DARK,
    YELLOW,
)
from snkit.kit import nuke_body, trefoil
from snkit.shapes import cylinder, ellipsoid, revolve

from models._critter_kit import (
    BLUSH,
    BURNT_ORANGE,
    CHOCOLATE,
    GOLD,
    GOLD_DARK,
    HOT_PINK,
    LAVENDER,
    MAGENTA,
    SKY_GLOW,
    SNOW,
    SOFT_BLACK,
    SUN_GLOW,
    TURKEY_BROWN,
    WATTLE_RED,
    catmull,
    crown,
    direction,
    eyes,
    frame,
    joints_text,
    orbit_ring,
    oriented_ellipsoid,
    plate,
    smile,
    star,
    surface,
    tube,
    tup,
    v3,
)

BUDGET = 2800  # triangles per pet (aim 1,200-2,400)
MAT = "StudsSmall"  # body stud material at pet scale


# ------------------------------------------------------------------------------------------------
# Model wrapper: rarity / hover / joints -> the pivot string that ships in MeshAssets[key].pivot
# ------------------------------------------------------------------------------------------------


def _pet(key: str, rarity: str, hover: float = 0.0, budget: int = BUDGET) -> Model:
    """Start a pet model; `_done` writes the pivot string once the joints are known."""
    m = Model(key, "", budget=budget)
    m.rarity = rarity
    m.hover = hover
    m.joints = {}
    return m


def _done(m: Model) -> Model:
    """Finalise the pivot string: placement, facing, rarity, hover and animation joints."""
    m.pivot = (
        f"ground-contact centre (y = 0 under the pet's middle); faces -Z; rarity {m.rarity}; "
        f"hover {m.hover:g}; {joints_text(m.joints)}"
    )
    return m


# ------------------------------------------------------------------------------------------------
# Critter parts (all append into pieces the caller picked, so colours stay grouped)
# ------------------------------------------------------------------------------------------------


def _blob(piece, center, radii, rings=8, segments=14, deform=None):
    """Smooth toy blob (body / head). 8x14 keeps it round under smooth shading at pet scale."""
    ellipsoid(piece, center, radii, rings=rings, segments=segments, deform=deform)


def _underside(center, radii, x, z):
    """Height of an ellipsoid's underside at (x, z) (where a leg must reach up into)."""
    cx, cy, cz = center
    k = 1 - ((x - cx) / radii[0]) ** 2 - ((z - cz) / radii[2]) ** 2
    return cy - radii[1] * math.sqrt(max(k, 0.0))


def _overside(center, radii, x, z):
    """Height of an ellipsoid's top surface at (x, z) (back ridges, spines, saddles)."""
    cx, cy, cz = center
    k = 1 - ((x - cx) / radii[0]) ** 2 - ((z - cz) / radii[2]) ** 2
    return cy + radii[1] * math.sqrt(max(k, 0.0))


def _legs(piece, body_c, body_r, spread=0.55, front=0.55, back=0.55, leg_r=0.19, bury=0.16, count=4):
    """
    Stubby toy legs: rounded ellipsoids from the ground (y = 0) up into the body underside.
    count=4 -> four legs at (+-spread*rx, front/back*rz); count=2 -> two legs side by side.
    """
    cx, _, cz = body_c
    rows = ((-1, front), (1, back)) if count == 4 else ((0, 0.0),)
    for sx in (-1, 1):
        for sz, f in rows:
            x = cx + sx * body_r[0] * spread
            z = cz + sz * body_r[2] * f
            top = _underside(body_c, body_r, x, z) + bury
            h = max(top / 2, 0.08)
            ellipsoid(piece, (x, h, z), (leg_r, h, leg_r * 1.08), rings=6, segments=10)


def _face(m, hc, hr, prefix="Head", eye_yaw=27.0, eye_pitch=6.0, eye_size=0.15, tall=1.25, mouth=True,
          mouth_pitch=-16.0, mouth_w=13.0, face_color=SOFT_BLACK, shine=True, neon_eyes=False):
    """Eyes (+ highlights) and a smile on an ellipsoid head. Returns (face_piece, shine_piece)."""
    face = m.piece(prefix + "Face", face_color, material="Neon" if neon_eyes else "Smooth")
    sh = m.piece(prefix + "Shine", SNOW, material="Smooth") if shine else None
    eyes(face, sh, hc, hr, yaw=eye_yaw, pitch=eye_pitch, size=eye_size, tall=tall)
    if mouth:
        smile(face, hc, hr, pitch=mouth_pitch, width=mouth_w)
    return face, sh


def _muzzle(piece, hc, hr, size=(0.3, 0.2, 0.2), pitch=-14.0, bury=0.55):
    """Axis-aligned muzzle / snout ellipsoid half-buried in the head front. Returns (centre, radii)."""
    p, n = surface(hc, hr, 0, pitch)
    c = p - n * (size[2] * bury)
    ellipsoid(piece, tup(c), size, rings=6, segments=12)
    return tup(c), size


def _nose(piece, mc, mr, pitch=28.0, size=(0.1, 0.07, 0.07)):
    """Little rounded nose on the top-front of a muzzle."""
    p, n = surface(mc, mr, 0, pitch)
    oriented_ellipsoid(piece, tup(p - n * 0.02), size, normal=tup(n), rings=5, segments=10)


def _ear_tri(piece, inner, hc, hr, side, yaw=38.0, pitch=50.0, w=0.24, h=0.5, lean=20.0, thick=0.14, sink=0.12):
    """Pointy cat / fox ear plate standing on the head, leaning outward; optional inner-ear plate."""
    p, _ = surface(hc, hr, side * yaw, pitch)
    lr = math.radians(lean)
    up = Vector((side * math.sin(lr), math.cos(lr), 0.0))
    fwd = direction(side * yaw * 0.6, 0)
    origin = p - up * sink
    outline = [(-w, 0), (w, 0), (w * 0.42, h * 0.72), (w * 0.12, h * 0.97), (-w * 0.12, h * 0.97), (-w * 0.42, h * 0.72)]
    plate(piece, outline, tup(origin), tup(fwd), tup(up), thick)
    if inner is not None:
        _, u_, n_ = frame(fwd, up)
        o2 = origin + n_ * (thick / 2 + 0.012) + u_ * (h * 0.16)
        plate(inner, [(x * 0.55, y * 0.6) for x, y in outline], tup(o2), tup(fwd), tup(up), 0.03)


def _ear_round(piece, inner, hc, hr, side, yaw=42.0, pitch=48.0, r=0.22, thick=0.13):
    """Round teddy / panda / mouse ear disc facing forward, half-buried in the head."""
    p, n = surface(hc, hr, side * yaw, pitch)
    fwd = direction(side * yaw * 0.5, 0)
    c = p + n * (r * 0.35)
    oriented_ellipsoid(piece, tup(c), (r, r, thick), normal=tup(fwd), rings=6, segments=12)
    if inner is not None:
        oriented_ellipsoid(inner, tup(c + fwd * (thick * 0.62)), (r * 0.6, r * 0.6, 0.04), normal=tup(fwd), rings=4, segments=10)


def _ear_long(piece, inner, hc, hr, side, yaw=22.0, pitch=62.0, length=0.55, width=0.17, lean=14.0, thick=0.1):
    """Long bunny ear: tall squashed ellipsoid rising from the head top, inner pad in front."""
    p, _ = surface(hc, hr, side * yaw, pitch)
    lr = math.radians(lean)
    up = Vector((side * math.sin(lr), math.cos(lr), 0.12)).normalized()
    fwd = direction(side * 8, 0)
    c = p + up * (length * 0.78)
    oriented_ellipsoid(piece, tup(c), (width, length, thick), normal=tup(fwd), up=tup(up), rings=8, segments=10)
    if inner is not None:
        _, _, n_ = frame(fwd, up)
        oriented_ellipsoid(inner, tup(c + n_ * (thick * 0.7) + up * 0.04), (width * 0.55, length * 0.72, 0.04), normal=tup(fwd), up=tup(up), rings=6, segments=8)


def _ear_floppy(piece, hc, hr, side, yaw=78.0, pitch=28.0, length=0.42, width=0.2, thick=0.11):
    """Floppy puppy ear hanging down the side of the head, tip flared out."""
    p, _ = surface(hc, hr, side * yaw, pitch)
    up = Vector((-side * 0.35, 1.0, 0.0)).normalized()
    c = p + Vector((side * 0.04, -length * 0.62, 0.02))
    oriented_ellipsoid(piece, tup(c), (width, length, thick), normal=(side, 0, 0), up=tup(up), rings=7, segments=10)


def _tail(piece, ctrl, r0, r1, sides=7, per=4, tip=True):
    """Tapered smooth tail along control points (base buried in the body first)."""
    pts = catmull(ctrl, per)
    n = len(pts)
    radii = [r0 + (r1 - r0) * (i / (n - 1)) for i in range(n)]
    tube(piece, pts, r0, sides=sides, radii=radii)
    if tip:
        ellipsoid(piece, pts[-1], (r1 * 1.05, r1 * 1.05, r1 * 1.05), rings=5, segments=sides + 1)
    return pts


def _horn(piece, base, tip, r0, turns=2.5, ridge=True, sides=8):
    """Spiral unicorn / narwhal horn: tapered cone + a thin helical ridge (same piece)."""
    b, t = v3(base), v3(tip)
    axis = t - b
    steps = 8
    pts = [tup(b + axis * (i / steps)) for i in range(steps + 1)]
    radii = [max(r0 * (1 - i / steps), 0.025) for i in range(steps + 1)]
    tube(piece, pts, r0, sides=sides, radii=radii)
    if ridge:
        s_, u_, _ = frame(axis.normalized())
        spiral = []
        count = 18
        for i in range(count + 1):
            f = i / count * 0.92
            ang = 2 * math.pi * turns * f
            rr = max(r0 * (1 - f), 0.03) * 1.02
            spiral.append(tup(b + axis * f + (s_ * math.cos(ang) + u_ * math.sin(ang)) * rr))
        tube(piece, spiral, r0 * 0.16, sides=4)


def _glow_badge(glow, center, normal, radius=0.16, up=(0, 1, 0)):
    """Neon radiation trefoil 'birthmark' standing just proud of a surface."""
    n = v3(normal).normalized()
    trefoil(glow, tup(v3(center) + n * 0.02), radius, 0.05, normal=tup(n), up=up)


def _spots(piece, center, radii, places, size=0.11, flat=0.05):
    """Squashed round spots stuck on an ellipsoid surface at (yaw, pitch[, scale]) places."""
    for place in places:
        yaw, pitch = place[0], place[1]
        s = place[2] if len(place) > 2 else 1.0
        p, n = surface(center, radii, yaw, pitch)
        oriented_ellipsoid(piece, tup(p - n * 0.01), (size * s, size * s, flat), normal=tup(n), rings=4, segments=8)


def _orbit(m, center, radius, color=GLOW_GREEN, rings=((-22.0, -18.0),), thickness=0.045, electrons=1, name="Orbit"):
    """Neon atom orbit ring(s) around the pet (spins as group 'Orbit' about its centre)."""
    piece = m.piece(name, color, material="Neon")
    for tilt_x, tilt_z in rings:
        orbit_ring(piece, center, radius, thickness, tilt_x=tilt_x, tilt_z=tilt_z, segments=28, sides=5, electrons=electrons, electron_r=0.09)
    m.joints["Orbit"] = center
    return piece


def _wing_plate(piece, outline, shoulder, side, back=0.6, lift=0.15, thick=0.08):
    """
    Spread wing plate. `outline` is (span, up) with span measured OUTWARD from the shoulder, so the
    same outline serves both sides. The wing plane sweeps outward-and-back by `back`.
    """
    a = Vector((side, lift, back)).normalized()
    u = Vector((0.0, 1.0, 0.0))
    u = (u - a * u.dot(a)).normalized()
    n = a.cross(u)
    plate(piece, outline, shoulder, tup(n), tup(u), thick)


def _std_quadruped(m, color, body_c=(0, 0.7, 0.18), body_r=(0.55, 0.5, 0.68), head_c=(0, 1.42, -0.3),
                   head_r=(0.7, 0.6, 0.6), legs=True, leg_r=0.19, leg_piece=None, head_color=None):
    """Chibi four-legger: small body + big head. Returns (body, head, body_c, body_r, head_c, head_r)."""
    body = m.piece("Body", color, material=MAT)
    _blob(body, body_c, body_r)
    if legs:
        _legs(leg_piece or body, body_c, body_r, leg_r=leg_r)
    head = m.piece("Head", head_color or color, material=MAT)
    _blob(head, head_c, head_r, rings=10, segments=16)
    m.joints["Head"] = (0.0, (body_c[1] + head_c[1]) / 2 + 0.05, (body_c[2] + head_c[2]) / 2 - 0.05)
    return body, head, body_c, body_r, head_c, head_r


# ------------------------------------------------------------------------------------------------
# COMMON
# ------------------------------------------------------------------------------------------------


def build_glow_slime():
    """Glow Slime: translucent lime jelly drop with a Neon core inside, droplets round its foot."""
    m = _pet("GlowSlime", "Common")
    body = m.piece("Body", LIME, material="Glass", transparency=0.3)
    c, r = (0, 0.47, 0), (0.86, 0.62, 0.8)

    def squish(x, y, z):
        # Flatten the bottom into a puddle foot and pinch the top into a soft-serve peak.
        if y < -0.4:
            y = -0.4 + (y + 0.4) * 0.3
        k = max(0.0, 1 - (x * x + z * z) / 0.18)
        return (x * (1 + 0.06 * (y < 0)), y + 0.22 * k * (y > 0.3), z)

    _blob(body, c, r, rings=10, segments=16, deform=squish)
    # A curled tip on the peak and droplets around the foot (same glass piece).
    ellipsoid(body, (0.06, 1.2, 0.05), (0.13, 0.12, 0.13), rings=5, segments=8)
    for i in range(6):
        a = 2 * math.pi * i / 6 + 0.4
        ellipsoid(body, (math.cos(a) * 0.86, 0.09, math.sin(a) * 0.78), (0.16, 0.09, 0.16), rings=4, segments=8)
    core = m.piece("Glow", GLOW_GREEN, material="Neon")
    ellipsoid(core, (0, 0.5, 0.08), (0.3, 0.28, 0.3), rings=6, segments=10)
    face = m.piece("Face", SOFT_BLACK, material="Smooth")
    shine = m.piece("Shine", SNOW, material="Smooth")
    hc, hr = (0, 0.5, 0), (0.88, 0.66, 0.82)
    eyes(face, shine, hc, hr, yaw=21, pitch=12, size=0.17, tall=1.3)
    smile(face, hc, hr, pitch=-6, width=11)
    return _done(m)


def build_atom_pup():
    """Atom Pup: golden puppy, cream muzzle, brown floppy ears, red collar with a Neon trefoil tag."""
    m = _pet("AtomPup", "Common")
    pup = (255, 200, 110)
    body, head, bc, br_, hc, hr = _std_quadruped(m, pup)
    accent = m.piece("HeadAccent", CREAM, material=MAT)
    mc, mr = _muzzle(accent, hc, hr, size=(0.3, 0.2, 0.22), pitch=-16)
    ears = m.piece("HeadEars", WOOD_DARK, material=MAT)
    for side in (-1, 1):
        _ear_floppy(ears, hc, hr, side)
    face, _ = _face(m, hc, hr, eye_yaw=26, eye_pitch=10, eye_size=0.15, mouth=False)
    _nose(face, mc, mr, pitch=40, size=(0.11, 0.08, 0.08))
    smile(face, mc, mr, pitch=-22, width=24, depth=10, thickness=0.03)
    collar = m.piece("Collar", TOY_RED, material=MAT)
    tube(collar, [tup(p) for p in _ring(0, 0.92, -0.08, 0.5, 0.5, tilt=24)], 0.075, sides=6, closed=True)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    _glow_badge(glow, (0, 0.6, -0.6), (0, -0.2, -1), radius=0.13)
    tail = m.piece("Tail", pup, material=MAT)
    _tail(tail, [(0, 0.8, 0.7), (0, 1.0, 0.92), (0.05, 1.28, 1.0)], 0.1, 0.07)
    m.joints["Tail"] = (0, 0.82, 0.74)
    return _done(m)


def _ring(cx, cy, cz, rx, rz, tilt=0.0, segments=16):
    """Horizontal ellipse loop (collars, belts) tipped forward-down by `tilt` degrees."""
    t = math.radians(tilt)
    pts = []
    for i in range(segments):
        a = 2 * math.pi * i / segments
        x, z = rx * math.cos(a), rz * math.sin(a)
        pts.append(Vector((cx + x, cy - z * math.sin(t), cz + z * math.cos(t))))
    return pts


def build_isotope_kitty():
    """Isotope Kitty: lavender kitten, pink inner ears, white bib + socks, Neon forehead stripes."""
    m = _pet("IsotopeKitty", "Common")
    body, head, bc, br_, hc, hr = _std_quadruped(m, LAVENDER, head_r=(0.72, 0.58, 0.58))
    belly = m.piece("Belly", SNOW, material=MAT)
    oriented_ellipsoid(belly, (0, 0.78, -0.3), (0.34, 0.32, 0.12), normal=(0, -0.2, -1), rings=6, segments=10)
    for sx in (-1, 1):
        ellipsoid(belly, (sx * 0.3, 0.08, bc[2] - br_[2] * 0.55 - 0.02), (0.2, 0.09, 0.22), rings=4, segments=10)
    pink = m.piece("HeadAccent", BLUSH, material="Smooth")
    for side in (-1, 1):
        _ear_tri(head, pink, hc, hr, side, yaw=36, pitch=46, w=0.25, h=0.48, lean=16)
    _spots(pink, hc, hr, [(-34, -12, 1.0), (34, -12, 1.0)], size=0.1, flat=0.03)  # blush cheeks
    face, _ = _face(m, hc, hr, eye_yaw=25, eye_pitch=4, eye_size=0.16, mouth_pitch=-18, mouth_w=9)
    p, n = surface(hc, hr, 0, -8)
    oriented_ellipsoid(pink, tup(p), (0.07, 0.05, 0.04), normal=tup(n), rings=4, segments=8)  # nose
    glow = m.piece("HeadGlow", GLOW_GREEN, material="Neon")
    for k, yaw in enumerate((-9, 0, 9)):
        p1, n1 = surface(hc, hr, yaw, 34)
        p2, _ = surface(hc, hr, yaw * 1.1, 34 + (16 if k == 1 else 12))
        tube(glow, [tup(p1 + n1 * 0.01), tup(p2 + n1 * 0.01)], 0.035, sides=5)
    tail = m.piece("Tail", LAVENDER, material=MAT)
    _tail(tail, [(0, 0.75, 0.72), (0.1, 0.95, 1.0), (-0.05, 1.35, 1.1), (0.15, 1.6, 1.0)], 0.09, 0.07)
    m.joints["Tail"] = (0, 0.76, 0.74)
    return _done(m)


def build_quark_duck():
    """Quark Duck: yellow duckling, orange bill + webbed feet, wing nubs, Neon trefoil on the chest."""
    m = _pet("QuarkDuck", "Common")
    body = m.piece("Body", YELLOW, material=MAT)
    bc, br_ = (0, 0.66, 0.12), (0.6, 0.55, 0.7)

    def perky(x, y, z):
        # Lift the rump into a little upturned duck tail.
        return (x, y + max(0.0, z - 0.3) * 0.45, z + max(0.0, z - 0.4) * 0.2)

    _blob(body, bc, br_, deform=perky)
    head = m.piece("Head", YELLOW, material=MAT)
    hc, hr = (0, 1.42, -0.22), (0.52, 0.5, 0.5)
    _blob(head, hc, hr, rings=10, segments=16)
    # Little head tuft (three soft curls).
    for k, dx in enumerate((-0.07, 0.0, 0.07)):
        ellipsoid(head, (dx, 1.95 + 0.04 * (k == 1), -0.2), (0.07, 0.13, 0.07), rings=4, segments=8)
    m.joints["Head"] = (0, 1.08, -0.15)
    bill = m.piece("HeadBill", ORANGE, material="Smooth")
    p, n = surface(hc, hr, 0, -14)
    oriented_ellipsoid(bill, tup(p + n * 0.08), (0.27, 0.08, 0.2), normal=(0, 0, -1), rings=5, segments=12)
    _face(m, hc, hr, eye_yaw=30, eye_pitch=12, eye_size=0.14, mouth=False)
    feet = m.piece("Feet", ORANGE, material="Smooth")
    web = [(-0.2, 0.0), (-0.12, -0.32), (0.0, -0.2), (0.12, -0.32), (0.2, 0.0), (0.0, 0.08)]
    for sx in (-1, 1):
        plate(feet, web, (sx * 0.26, 0.05, -0.08), (0, 1, 0), (0, 0, 1), 0.08)
        cylinder(feet, (sx * 0.26, 0.05, 0.0), (sx * 0.26, 0.3, 0.05), 0.07, segments=6)
    for side, name in ((-1, "WingL"), (1, "WingR")):
        wing = m.piece(name, YELLOW, material=MAT)
        oriented_ellipsoid(wing, (side * 0.58, 0.72, 0.2), (0.34, 0.24, 0.09), normal=(side, 0, 0), up=(0, 0.8, 0.6), rings=6, segments=10)
        m.joints[name] = (side * 0.5, 0.82, 0.05)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    _glow_badge(glow, (0, 0.72, -0.56), (0, 0.1, -1), radius=0.14)
    return _done(m)


# ------------------------------------------------------------------------------------------------
# UNCOMMON
# ------------------------------------------------------------------------------------------------


def build_uranium_bunny():
    """Uranium Bunny: mint bunny, long pink-lined ears, cotton tail, hugging a glowing carrot."""
    m = _pet("UraniumBunny", "Uncommon")
    body, head, bc, br_, hc, hr = _std_quadruped(m, MINT, body_c=(0, 0.66, 0.2), body_r=(0.58, 0.55, 0.62), head_c=(0, 1.36, -0.22), head_r=(0.66, 0.56, 0.56))
    pink = m.piece("HeadAccent", BLUSH, material="Smooth")
    for side in (-1, 1):
        _ear_long(head, pink, hc, hr, side)
    _spots(pink, hc, hr, [(-36, -14), (36, -14)], size=0.1, flat=0.03)
    face, _ = _face(m, hc, hr, eye_yaw=25, eye_pitch=4, eye_size=0.15, mouth_pitch=-20, mouth_w=8)
    p, n = surface(hc, hr, 0, -8)
    oriented_ellipsoid(pink, tup(p), (0.07, 0.05, 0.04), normal=tup(n), rings=4, segments=8)
    belly = m.piece("Belly", SNOW, material=MAT)
    oriented_ellipsoid(belly, (0, 0.6, -0.34), (0.36, 0.36, 0.12), normal=(0, -0.1, -1), rings=6, segments=10)
    tail = m.piece("Tail", SNOW, material=MAT)
    ellipsoid(tail, (0, 0.72, 0.86), (0.22, 0.22, 0.2), rings=6, segments=10)
    m.joints["Tail"] = (0, 0.72, 0.74)
    # Glowing carrot held against the chest (Neon cone + leaf tuft).
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    cylinder(glow, (0.05, 0.98, -0.62), (-0.08, 0.32, -0.7), 0.14, segments=8, radius_b=0.03)
    for k in range(3):
        a = math.radians(-30 + 30 * k)
        tube(glow, [(0.05, 0.96, -0.62), (0.05 + math.sin(a) * 0.18, 1.2, -0.6)], 0.04, sides=4)
    return _done(m)


def build_neutron_newt():
    """Neutron Newt: low coral newt, wide grin, long tapered tail, glowing Neon back spots."""
    m = _pet("NeutronNewt", "Uncommon")
    coral = (255, 136, 86)
    body = m.piece("Body", coral, material=MAT)
    bc, br_ = (0, 0.42, 0.2), (0.48, 0.34, 0.75)
    _blob(body, bc, br_)
    # Splayed toy legs (sideways ellipsoids).
    for sx in (-1, 1):
        for z in (-0.25, 0.6):
            oriented_ellipsoid(body, (sx * 0.52, 0.14, z), (0.22, 0.1, 0.12), normal=(0, 0, 1), up=(0, 1, 0), rings=5, segments=8)
    head = m.piece("Head", coral, material=MAT)
    hc, hr = (0, 0.66, -0.6), (0.6, 0.42, 0.48)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 0.5, -0.38)
    _face(m, hc, hr, eye_yaw=34, eye_pitch=26, eye_size=0.14, mouth_pitch=-12, mouth_w=26)
    belly = m.piece("Belly", YELLOW, material=MAT)
    oriented_ellipsoid(belly, (0, 0.14, 0.15), (0.36, 0.08, 0.6), normal=(0, -1, 0), up=(0, 0, 1), rings=5, segments=10)
    tail = m.piece("Tail", coral, material=MAT)
    _tail(tail, [(0, 0.42, 0.75), (0.08, 0.36, 1.15), (-0.12, 0.3, 1.55), (0.02, 0.26, 1.85)], 0.2, 0.05)
    m.joints["Tail"] = (0, 0.42, 0.8)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    _spots(glow, bc, br_, [(150, 50), (-150, 50), (175, 38, 0.8), (110, 60, 0.7), (-110, 60, 0.7)], size=0.12)
    _spots(glow, hc, hr, [(160, 55, 0.8)], size=0.1)
    return _done(m)


def build_plasma_pig():
    """Plasma Pig: round pink piglet, snout puck, curly tail, hooves, Neon magenta plasma spots."""
    m = _pet("PlasmaPig", "Uncommon")
    pig = (255, 168, 196)
    snout_c = (238, 112, 152)
    hooves = m.piece("Hooves", snout_c, material=MAT)
    body, head, bc, br_, hc, hr = _std_quadruped(m, pig, body_c=(0, 0.72, 0.2), body_r=(0.62, 0.56, 0.7), head_r=(0.66, 0.58, 0.58), leg_piece=hooves, leg_r=0.17)
    snout = m.piece("HeadSnout", snout_c, material=MAT)
    mc, mr = _muzzle(snout, hc, hr, size=(0.24, 0.18, 0.12), pitch=-10, bury=0.3)
    for side in (-1, 1):
        _ear_tri(head, None, hc, hr, side, yaw=44, pitch=42, w=0.2, h=0.32, lean=40, thick=0.1)
    face, _ = _face(m, hc, hr, eye_yaw=30, eye_pitch=12, eye_size=0.14, mouth_pitch=-34, mouth_w=12)
    for sx in (-1, 1):
        p, n = surface(mc, mr, sx * 26, 0)
        oriented_ellipsoid(face, tup(p), (0.04, 0.06, 0.03), normal=tup(n), rings=4, segments=8)
    tail = m.piece("Tail", pig, material=MAT)
    spiral = [(0, 0.86, 0.86)]
    for i in range(1, 10):
        a = i * 0.75
        spiral.append((0.12 * math.sin(a), 0.98 + 0.12 * math.cos(a), 0.9 + 0.04 * i))
    tube(tail, spiral, 0.05, sides=5)
    m.joints["Tail"] = (0, 0.86, 0.84)
    glow = m.piece("Glow", MAGENTA, material="Neon")
    _spots(glow, bc, br_, [(120, 40), (-130, 35, 0.8), (165, 55, 0.7), (90, 10, 0.6)], size=0.13)
    return _done(m)


def build_mega_mole():
    """Mega Mole: chunky velvet mole, pink star nose + shovel paws, yellow mining helmet + Neon lamp."""
    m = _pet("MegaMole", "Uncommon")
    velvet = (152, 128, 144)  # light velvet mauve: dark eyes must read against it
    body = m.piece("Body", velvet, material=MAT)
    bc, br_ = (0, 0.78, 0.05), (0.8, 0.86, 0.74)
    # Flat-bottomed pear: clamp the underside at y = 0 so the mole sits flush on the ground.
    _blob(body, bc, br_, rings=10, segments=16, deform=lambda x, y, z: (x, max(y, -0.78), z))
    ellipsoid(body, (0, 0.5, 0.8), (0.1, 0.1, 0.12), rings=4, segments=8)  # stubby tail
    hc, hr = bc, br_
    _face(m, hc, hr, prefix="", eye_yaw=24, eye_pitch=16, eye_size=0.13, tall=1.15, mouth=False)
    pink = m.piece("Nose", PINK, material=MAT)
    p, n = surface(hc, hr, 0, 2)
    ellipsoid(pink, tup(p + n * 0.05), (0.16, 0.13, 0.12), rings=6, segments=10)
    for k in range(6):  # star-nose nubs
        a = 2 * math.pi * k / 6
        ellipsoid(pink, tup(p + n * 0.1 + Vector((math.cos(a) * 0.16, math.sin(a) * 0.13, 0))), (0.06, 0.06, 0.06), rings=4, segments=6)
    for sx in (-1, 1):  # big shovel paws raised at the body's front sides (waving hello)
        pc, pn = surface(hc, hr, sx * 52, -18)
        oriented_ellipsoid(pink, tup(pc + pn * 0.05), (0.22, 0.26, 0.1), normal=tup(pn), up=(sx * 0.3, 1, 0), rings=5, segments=10)
        s_, u_, n_ = frame(pn, (sx * 0.3, 1, 0))
        for k in (-1, 0, 1):
            ellipsoid(pink, tup(pc + pn * 0.08 + u_ * 0.26 + s_ * (k * 0.11)), (0.06, 0.07, 0.06), rings=4, segments=6)
    smile(m.pieces["Face"], hc, hr, pitch=-12, width=10)
    helmet = m.piece("Helmet", HAZARD_YELLOW, material=MAT)
    revolve(helmet, [(0.0, 1.88), (0.42, 1.84), (0.6, 1.62), (0.66, 1.42), (0.8, 1.4), (0.8, 1.33), (0.0, 1.33)], center=(0, 0, 0.03), segments=16)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    p, n = surface((0, 1.6, 0.03), (0.62, 0.3, 0.62), 0, 10)
    oriented_ellipsoid(glow, tup(p + n * 0.04), (0.15, 0.15, 0.08), normal=tup(n), rings=5, segments=10)
    return _done(m)


# ------------------------------------------------------------------------------------------------
# RARE
# ------------------------------------------------------------------------------------------------


def build_fission_fox():
    """Fission Fox: orange fox whose tail has split in two (white tips), white bib, one atom ring."""
    m = _pet("FissionFox", "Rare")
    fox = (255, 138, 48)
    body, head, bc, br_, hc, hr = _std_quadruped(m, fox, head_r=(0.72, 0.58, 0.58))
    white = m.piece("HeadAccent", SNOW, material=MAT)
    for side in (-1, 1):
        _ear_tri(head, white, hc, hr, side, yaw=34, pitch=44, w=0.26, h=0.56, lean=14)
    for side in (-1, 1):  # white cheek ruffs
        p, n = surface(hc, hr, side * 42, -22)
        oriented_ellipsoid(white, tup(p - n * 0.06), (0.24, 0.17, 0.12), normal=tup(n), rings=5, segments=10)
    mc, mr = _muzzle(white, hc, hr, size=(0.22, 0.15, 0.2), pitch=-18)
    face, _ = _face(m, hc, hr, eye_yaw=27, eye_pitch=8, eye_size=0.15, mouth=False)
    _nose(face, mc, mr, pitch=30)
    smile(face, mc, mr, pitch=-28, width=22, depth=8, thickness=0.028)
    bib = m.piece("Belly", SNOW, material=MAT)
    oriented_ellipsoid(bib, (0, 0.8, -0.32), (0.3, 0.3, 0.12), normal=(0, -0.2, -1), rings=6, segments=10)
    tail = m.piece("Tail", fox, material=MAT)
    tip = m.piece("TailTip", SNOW, material=MAT)
    for side in (-1, 1):
        pts = _tail(tail, [(0, 0.82, 0.75), (side * 0.1, 1.0, 1.02), (side * 0.2, 1.38, 1.12), (side * 0.24, 1.62, 1.0)], 0.13, 0.18, tip=False)
        ellipsoid(tip, pts[-1], (0.19, 0.22, 0.19), rings=6, segments=10)
    m.joints["Tail"] = (0, 0.82, 0.76)
    _orbit(m, (0, 1.05, 0.0), 0.97)
    return _done(m)


def build_reactor_owl():
    """Reactor Owl: round teal owl, big white eye discs, ear tufts, Neon chest core, one atom ring."""
    m = _pet("ReactorOwl", "Rare", hover=0.8)
    teal = (70, 150, 205)
    body = m.piece("Body", teal, material=MAT)
    bc, br_ = (0, 0.95, 0.0), (0.78, 0.95, 0.72)
    _blob(body, bc, br_, rings=10, segments=16)
    for side in (-1, 1):  # ear tufts
        plate(body, [(-0.16, 0), (0.16, 0), (0.06, 0.34), (-0.02, 0.38)], (side * 0.42, 1.68, -0.1), (0, 0, -1), (side * 0.45, 1, 0), 0.12)
    belly = m.piece("Belly", CREAM, material=MAT)
    p, n = surface(bc, br_, 0, -22)
    oriented_ellipsoid(belly, tup(p - n * 0.1), (0.5, 0.52, 0.14), normal=tup(n), rings=6, segments=12)
    discs = m.piece("Shine", SNOW, material="Smooth")
    face = m.piece("Face", SOFT_BLACK, material="Smooth")
    for side in (-1, 1):
        p, n = surface(bc, br_, side * 24, 22)
        oriented_ellipsoid(discs, tup(p - n * 0.02), (0.27, 0.27, 0.08), normal=tup(n), rings=5, segments=14)
        pc = p + n * 0.05
        oriented_ellipsoid(face, tup(pc), (0.13, 0.15, 0.06), normal=tup(n), rings=5, segments=10)
        s_, u_, n_ = frame(n)
        oriented_ellipsoid(discs, tup(pc + n_ * 0.05 + u_ * 0.06 - s_ * side * 0.04), (0.05, 0.05, 0.03), normal=tup(n), rings=4, segments=8)
    beak = m.piece("Beak", ORANGE, material="Smooth")
    p, n = surface(bc, br_, 0, 12)
    plate(beak, [(-0.1, 0.06), (0.1, 0.06), (0.0, -0.16)], tup(p + n * 0.04), tup(n), (0, 1, 0), 0.12)
    for sx in (-1, 1):  # orange toes
        for k in (-1, 0, 1):
            ellipsoid(beak, (sx * 0.28 + k * 0.08, 0.05, -0.42), (0.05, 0.05, 0.1), rings=4, segments=6)
    for side, name in ((-1, "WingL"), (1, "WingR")):
        wing = m.piece(name, (46, 104, 160), material=MAT)
        oriented_ellipsoid(wing, (side * 0.74, 0.92, 0.12), (0.5, 0.3, 0.1), normal=(side, 0, -0.15), up=(0, 0.4, 0.9), rings=6, segments=10)
        m.joints[name] = (side * 0.62, 1.2, 0.05)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    p, n = surface(bc, br_, 0, -24)
    _glow_badge(glow, tup(p + n * 0.05), tup(n), radius=0.17)
    _orbit(m, (0, 1.05, 0.0), 1.01, rings=((70.0, 20.0),))
    return _done(m)


def build_proton_panda():
    """Proton Panda: white panda, black ears / patches / limbs, hugging a glowing pink proton ball."""
    m = _pet("ProtonPanda", "Rare")
    black = m.piece("Limbs", SOFT_BLACK, material=MAT)
    body, head, bc, br_, hc, hr = _std_quadruped(m, SNOW, body_c=(0, 0.72, 0.18), body_r=(0.62, 0.58, 0.66), head_r=(0.74, 0.62, 0.6), leg_piece=black, leg_r=0.22)
    # Black shoulder band.
    tube(black, [tup(p) for p in _ring(0, 0.95, 0.05, 0.6, 0.55, tilt=-10)], 0.14, sides=6, closed=True)
    hb = m.piece("HeadBlack", SOFT_BLACK, material=MAT)
    whites = m.piece("HeadShine", SNOW, material="Smooth")
    for side in (-1, 1):
        _ear_round(hb, None, hc, hr, side, yaw=44, pitch=46, r=0.22)
        p, n = surface(hc, hr, side * 28, 4)
        oriented_ellipsoid(hb, tup(p - n * 0.05), (0.2, 0.25, 0.1), normal=tup(n), up=(-side * 0.5, 1, 0), rings=6, segments=12)
        pe = p + n * 0.04
        oriented_ellipsoid(whites, tup(pe), (0.1, 0.12, 0.05), normal=tup(n), rings=5, segments=10)
        oriented_ellipsoid(hb, tup(pe + n * 0.035), (0.06, 0.075, 0.03), normal=tup(n), rings=4, segments=8)
        s_, u_, n_ = frame(n)
        oriented_ellipsoid(whites, tup(pe + n_ * 0.06 + u_ * 0.03 - s_ * side * 0.02), (0.025, 0.025, 0.015), normal=tup(n), rings=3, segments=6)
    p, n = surface(hc, hr, 0, -16)
    oriented_ellipsoid(hb, tup(p), (0.1, 0.07, 0.06), normal=tup(n), rings=4, segments=8)
    smile(hb, hc, hr, pitch=-28, width=9)
    glow = m.piece("Glow", HOT_PINK, material="Neon")
    ellipsoid(glow, (0, 0.62, -0.62), (0.24, 0.24, 0.24), rings=6, segments=10)
    for sx in (-1, 1):  # paws hugging the proton
        ellipsoid(black, (sx * 0.28, 0.66, -0.56), (0.16, 0.14, 0.16), rings=5, segments=8)
    _orbit(m, (0, 1.05, 0.0), 1.01, color=HOT_PINK)
    return _done(m)


def build_gamma_gator():
    """Gamma Gator: green gator, long smiley snout with white tooth nubs, Neon back spines."""
    m = _pet("GammaGator", "Rare")
    green = (96, 194, 90)
    body = m.piece("Body", green, material=MAT)
    bc, br_ = (0, 0.46, 0.22), (0.52, 0.38, 0.78)
    _blob(body, bc, br_)
    for sx in (-1, 1):
        for z in (-0.25, 0.65):
            oriented_ellipsoid(body, (sx * 0.5, 0.15, z), (0.2, 0.15, 0.17), normal=(0, 0, 1), rings=5, segments=8)
    belly = m.piece("Belly", CREAM, material=MAT)
    oriented_ellipsoid(belly, (0, 0.2, 0.2), (0.4, 0.1, 0.66), normal=(0, -1, 0), up=(0, 0, 1), rings=5, segments=10)
    head = m.piece("Head", green, material=MAT)
    hc, hr = (0, 0.82, -0.58), (0.56, 0.46, 0.5)
    _blob(head, hc, hr, rings=10, segments=16)
    snout_c, snout_r = (0, 0.66, -1.05), (0.42, 0.24, 0.42)
    _blob(head, snout_c, snout_r, rings=6, segments=12)
    for sx in (-1, 1):  # eye bumps on top
        ellipsoid(head, (sx * 0.24, 1.18, -0.6), (0.17, 0.16, 0.16), rings=6, segments=10)
    m.joints["Head"] = (0, 0.6, -0.38)
    face = m.piece("HeadFace", SOFT_BLACK, material="Smooth")
    shine = m.piece("HeadShine", SNOW, material="Smooth")
    for sx in (-1, 1):
        ec, er = (sx * 0.24, 1.18, -0.6), (0.17, 0.16, 0.16)
        eyes_c, n = surface(ec, er, 0, 10)
        oriented_ellipsoid(face, tup(eyes_c - n * 0.02), (0.09, 0.11, 0.05), normal=tup(n), rings=5, segments=10)
        oriented_ellipsoid(shine, tup(eyes_c + n * 0.03 + Vector((sx * -0.03, 0.04, 0))), (0.03, 0.03, 0.015), normal=tup(n), rings=3, segments=6)
        p, n = surface(snout_c, snout_r, sx * 18, 50)
        oriented_ellipsoid(face, tup(p), (0.035, 0.03, 0.02), normal=tup(n), rings=3, segments=6)  # nostrils
    smile(face, snout_c, snout_r, pitch=-24, width=38, depth=-6, thickness=0.03, steps=8)
    teeth = m.piece("HeadTeeth", SNOW, material="Smooth")
    for k in range(-2, 3):
        p, n = surface(snout_c, snout_r, k * 16, -22)
        plate(teeth, [(-0.04, 0.0), (0.04, 0.0), (0.0, -0.08)], tup(p + n * 0.02), tup(n), (0, 1, 0), 0.04)
    tail = m.piece("Tail", green, material=MAT)
    _tail(tail, [(0, 0.45, 0.8), (0.1, 0.4, 1.2), (-0.1, 0.34, 1.6), (0.05, 0.28, 1.9)], 0.24, 0.06)
    m.joints["Tail"] = (0, 0.45, 0.85)
    glow = m.piece("Glow", LIME, material="Neon")
    for i, z in enumerate((-0.2, 0.15, 0.5, 0.85)):
        y = _overside(bc, br_, 0, z)
        h = 0.2 - 0.03 * i
        plate(glow, [(-0.12, 0), (0.12, 0), (0, h)], (0, y - 0.04, z), (1, 0, 0), (0, 1, 0), 0.08)
    _orbit(m, (0, 0.8, 0.1), 1.05, rings=((-18.0, 12.0),))
    return _done(m)


# ------------------------------------------------------------------------------------------------
# EPIC
# ------------------------------------------------------------------------------------------------


def build_nuclear_narwhal():
    """Nuclear Narwhal: floating sky-blue narwhal, white belly, Neon spiral horn, two atom rings."""
    m = _pet("NuclearNarwhal", "Epic", hover=1.0)
    blue = (96, 156, 236)
    body = m.piece("Body", blue, material=MAT)
    bc, br_ = (0, 0.66, 0.1), (0.7, 0.66, 0.95)

    def taper(x, y, z):
        # Narrow the back half toward the tail stock.
        f = 1.0 - 0.45 * max(0.0, z / 0.95) ** 1.5
        return (x * f, y * f + 0.08 * max(0.0, z) , z)

    _blob(body, bc, br_, rings=10, segments=16, deform=taper)
    belly = m.piece("Belly", SNOW, material=MAT)
    oriented_ellipsoid(belly, (0, 0.28, -0.05), (0.5, 0.14, 0.7), normal=(0, -1, -0.2), up=(0, 0, 1), rings=6, segments=12)
    hc, hr = (0, 0.7, 0.0), (0.72, 0.68, 0.92)
    _face(m, hc, hr, prefix="", eye_yaw=30, eye_pitch=10, eye_size=0.15, mouth_pitch=-14, mouth_w=14)
    horn = m.piece("Horn", SUN_GLOW, material="Neon")
    _horn(horn, (0, 1.1, -0.72), (0, 1.75, -1.55), 0.13, turns=3)
    tail = m.piece("Tail", blue, material=MAT)
    fluke = [(0, -0.05), (0.42, 0.25), (0.55, 0.42), (0.3, 0.32), (0.0, 0.18), (-0.3, 0.32), (-0.55, 0.42), (-0.42, 0.25)]
    plate(tail, fluke, (0, 0.95, 1.05), (0, 1, 0), (0, 0, 1), 0.1)
    tube(tail, [(0, 0.82, 0.85), (0, 0.95, 1.1)], 0.13, sides=6)
    m.joints["Tail"] = (0, 0.85, 0.85)
    for side, name in ((-1, "WingL"), (1, "WingR")):
        fin = m.piece(name, blue, material=MAT)
        oriented_ellipsoid(fin, (side * 0.72, 0.36, -0.15), (0.32, 0.08, 0.18), normal=(0, 1, 0), up=(side, 0, 0.5), rings=5, segments=10)
        m.joints[name] = (side * 0.58, 0.42, -0.15)
    _orbit(m, (0, 0.75, 0.05), 1.09, color=SKY_GLOW, rings=((-24.0, -20.0), (-10.0, 36.0)))
    return _done(m)


def build_cosmic_corgi():
    """Cosmic Corgi: orange-and-white corgi in a glass space-bubble helmet, Neon star tag, ring."""
    m = _pet("CosmicCorgi", "Epic")
    corgi = (246, 150, 62)
    white = m.piece("Belly", SNOW, material=MAT)
    body, head, bc, br_, hc, hr = _std_quadruped(m, corgi, body_c=(0, 0.62, 0.2), body_r=(0.58, 0.45, 0.78), head_c=(0, 1.3, -0.36), head_r=(0.66, 0.56, 0.56), leg_piece=white, leg_r=0.17)
    oriented_ellipsoid(white, (0, 0.6, -0.4), (0.34, 0.3, 0.12), normal=(0, -0.1, -1), rings=6, segments=10)
    acc = m.piece("HeadAccent", SNOW, material=MAT)
    for side in (-1, 1):
        _ear_tri(head, acc, hc, hr, side, yaw=40, pitch=40, w=0.27, h=0.55, lean=22)
    mc, mr = _muzzle(acc, hc, hr, size=(0.26, 0.17, 0.2), pitch=-16)
    p, n = surface(hc, hr, 0, 20)
    tube(acc, [tup(p + n * 0.01), tup(surface(hc, hr, 0, 50)[0])], 0.07, sides=6)  # white blaze
    face, _ = _face(m, hc, hr, eye_yaw=27, eye_pitch=6, eye_size=0.14, mouth=False)
    _nose(face, mc, mr, pitch=32)
    smile(face, mc, mr, pitch=-26, width=22, depth=8, thickness=0.028)
    helmet = m.piece("HeadHelmet", GLASS, material="Glass", transparency=0.6)
    ellipsoid(helmet, (0, 1.42, -0.36), (0.98, 0.9, 0.9), rings=10, segments=18)
    ring = m.piece("HeadRing", (190, 196, 210), material=MAT)
    tube(ring, [tup(p) for p in _ring(0, 0.72, -0.3, 0.72, 0.62, tilt=-8, segments=18)], 0.08, sides=6, closed=True)
    tail = m.piece("Tail", corgi, material=MAT)
    ellipsoid(tail, (0, 0.8, 0.98), (0.14, 0.14, 0.16), rings=5, segments=8)
    m.joints["Tail"] = (0, 0.78, 0.9)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    star(glow, (0, 0.38, -0.62), 0.15, 0.06, normal=(0, 0, -1))
    return _done(m)


def build_rad_raccoon():
    """Rad Raccoon: grey raccoon, bandit mask, white brows + muzzle, Neon-ringed tail, two rings."""
    m = _pet("RadRaccoon", "Epic")
    grey = (150, 152, 168)
    body, head, bc, br_, hc, hr = _std_quadruped(m, grey, head_r=(0.74, 0.58, 0.58))
    mask = m.piece("HeadMask", SOFT_BLACK, material=MAT)
    whites = m.piece("HeadWhite", SNOW, material="Smooth")
    for side in (-1, 1):
        _ear_tri(head, whites, hc, hr, side, yaw=40, pitch=44, w=0.22, h=0.38, lean=22)
        p, n = surface(hc, hr, side * 28, 4)
        oriented_ellipsoid(mask, tup(p - n * 0.05), (0.26, 0.17, 0.1), normal=tup(n), up=(side * 0.25, 1, 0), rings=6, segments=12)
        pe = p + n * 0.035
        oriented_ellipsoid(whites, tup(pe), (0.1, 0.11, 0.05), normal=tup(n), rings=5, segments=10)
        oriented_ellipsoid(mask, tup(pe + n * 0.035), (0.06, 0.07, 0.03), normal=tup(n), rings=4, segments=8)
        s_, u_, n_ = frame(n)
        oriented_ellipsoid(whites, tup(pe + n_ * 0.06 + u_ * 0.03 - s_ * side * 0.02), (0.025, 0.025, 0.015), normal=tup(n), rings=3, segments=6)
        pb, nb = surface(hc, hr, side * 24, 24)
        oriented_ellipsoid(whites, tup(pb), (0.14, 0.05, 0.04), normal=tup(nb), rings=4, segments=8)  # brows
    mc, mr = _muzzle(whites, hc, hr, size=(0.24, 0.16, 0.2), pitch=-18)
    _nose(mask, mc, mr, pitch=34)
    smile(mask, mc, mr, pitch=-26, width=22, depth=8, thickness=0.028)
    tail = m.piece("Tail", grey, material=MAT)
    rings = m.piece("TailGlow", GLOW_GREEN, material="Neon")
    pts = _tail(tail, [(0, 0.8, 0.72), (0.1, 1.0, 1.05), (0.0, 1.4, 1.2), (-0.1, 1.7, 1.08)], 0.17, 0.15, sides=6, per=3)
    for k in (2, 5, 8):
        i = min(k, len(pts) - 2)
        a, b = v3(pts[i]), v3(pts[i + 1])
        tube(rings, [tup(a + (b - a) * 0.15), tup(a + (b - a) * 0.75)], 0.18, sides=6)
    m.joints["Tail"] = (0, 0.8, 0.74)
    _orbit(m, (0, 1.05, 0.0), 1.05, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


def build_atomic_axolotl():
    """Atomic Axolotl: pink axolotl, wide smile, three Neon gill fronds per side, finned tail."""
    m = _pet("AtomicAxolotl", "Epic", hover=0.4)
    pink = (255, 172, 204)
    body = m.piece("Body", pink, material=MAT)
    bc, br_ = (0, 0.46, 0.25), (0.46, 0.4, 0.72)
    _blob(body, bc, br_)
    for sx in (-1, 1):
        for z in (-0.15, 0.62):
            oriented_ellipsoid(body, (sx * 0.46, 0.14, z), (0.2, 0.12, 0.12), normal=(0, 0, 1), rings=5, segments=8)
    head = m.piece("Head", pink, material=MAT)
    hc, hr = (0, 0.82, -0.45), (0.74, 0.52, 0.55)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 0.62, -0.2)
    _face(m, hc, hr, eye_yaw=36, eye_pitch=10, eye_size=0.13, mouth_pitch=-14, mouth_w=24)
    gills = m.piece("HeadGlow", MAGENTA, material="Neon")
    for side in (-1, 1):
        root, _ = surface(hc, hr, side * 80, 10)
        for k, ang in enumerate((40, 5, -30)):
            a = math.radians(ang)
            end = root + Vector((side * 0.42 * math.cos(a), 0.42 * math.sin(a) + 0.08, 0.12))
            mid = root.lerp(end, 0.5) + Vector((0, 0.06, 0))
            tube(gills, [tup(root), tup(mid), tup(end)], 0.06, sides=5, radii=[0.07, 0.06, 0.04])
            for f in (0.45, 0.75):  # feathery nubs
                q = root.lerp(end, f)
                ellipsoid(gills, tup(q + Vector((0, 0.05, 0))), (0.04, 0.06, 0.04), rings=3, segments=6)
    tail = m.piece("Tail", pink, material=MAT)
    _tail(tail, [(0, 0.48, 0.85), (0.05, 0.5, 1.2), (-0.05, 0.5, 1.5)], 0.18, 0.06)
    plate(tail, [(-0.02, -0.12), (0.8, -0.05), (1.0, 0.0), (0.8, 0.12), (0.0, 0.2)], (0, 0.5, 0.85), (1, 0, 0), (0, 1, 0), 0.04)
    m.joints["Tail"] = (0, 0.48, 0.88)
    _orbit(m, (0, 0.75, 0.15), 1.05, color=HOT_PINK, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


# ------------------------------------------------------------------------------------------------
# LEGENDARY
# ------------------------------------------------------------------------------------------------


def _antler(piece, base, side, scale=1.0):
    """Palmate cartoon moose antler: a stem + a flat palm with three rounded points, leaning out."""
    s = scale
    outline = [(0.0, -0.06), (0.12, -0.06), (0.2, 0.18), (0.62, 0.22), (0.7, 0.42), (0.58, 0.44), (0.54, 0.34),
               (0.48, 0.5), (0.36, 0.52), (0.34, 0.38), (0.26, 0.52), (0.14, 0.5), (0.1, 0.3), (-0.04, 0.3)]
    outline = [(x * s, y * s) for x, y in outline]
    _wing_plate(piece, outline, base, side, back=-0.15, lift=0.35, thick=0.1)


def build_meltdown_moose():
    """Meltdown Moose: cuddly moose, big tan muzzle, gold antlers dripping Neon goo, two rings."""
    m = _pet("MeltdownMoose", "Legendary")
    brown = (176, 112, 72)
    hooves = m.piece("Hooves", CHOCOLATE, material=MAT)
    body, head, bc, br_, hc, hr = _std_quadruped(m, brown, body_c=(0, 0.82, 0.18), body_r=(0.6, 0.56, 0.74), head_c=(0, 1.55, -0.3), head_r=(0.6, 0.55, 0.55), leg_piece=hooves, leg_r=0.17)
    muzzle = m.piece("HeadMuzzle", (226, 180, 130), material=MAT)
    mc, mr = _muzzle(muzzle, hc, hr, size=(0.42, 0.3, 0.32), pitch=-26, bury=0.5)
    face, _ = _face(m, hc, hr, eye_yaw=30, eye_pitch=14, eye_size=0.14, mouth=False)
    for sx in (-1, 1):
        p, n = surface(mc, mr, sx * 24, 18)
        oriented_ellipsoid(face, tup(p), (0.05, 0.07, 0.03), normal=tup(n), rings=4, segments=8)
    smile(face, mc, mr, pitch=-20, width=26, depth=8, thickness=0.03)
    for side in (-1, 1):
        _ear_tri(head, None, hc, hr, side, yaw=70, pitch=22, w=0.13, h=0.3, lean=70, thick=0.1)
    antlers = m.piece("HeadAntlers", GOLD, material=MAT)
    goo = m.piece("HeadGlow", GLOW_GREEN, material="Neon")
    for side in (-1, 1):
        base, _ = surface(hc, hr, side * 40, 52)
        _antler(antlers, tup(base - Vector((0, 0.05, 0))), side)
        for k, off in enumerate((0.0, 0.18)):
            q = base + Vector((side * (0.3 + off), 0.24 - k * 0.04, 0.05 + off * 0.3))
            ellipsoid(goo, tup(q), (0.06, 0.11, 0.06), rings=4, segments=8)
            ellipsoid(goo, tup(q - Vector((0, 0.14, 0))), (0.045, 0.06, 0.045), rings=3, segments=6)
    tail = m.piece("Tail", brown, material=MAT)
    ellipsoid(tail, (0, 1.1, 0.9), (0.1, 0.14, 0.1), rings=4, segments=8)
    m.joints["Tail"] = (0, 1.05, 0.86)
    _orbit(m, (0, 1.2, 0.05), 1.13, color=GLOW_GREEN, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


def build_fusion_phoenix():
    """Fusion Phoenix: candy firebird (no realistic fire): flame-shaped wings, Neon crest + sun core."""
    m = _pet("FusionPhoenix", "Legendary", hover=1.0)
    flame = (255, 132, 40)
    body = m.piece("Body", flame, material=MAT)
    bc, br_ = (0, 0.7, 0.1), (0.48, 0.55, 0.62)
    _blob(body, bc, br_)
    head = m.piece("Head", flame, material=MAT)
    hc, hr = (0, 1.38, -0.2), (0.5, 0.48, 0.48)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 1.05, -0.12)
    beak = m.piece("HeadBeak", YELLOW, material="Smooth")
    p, n = surface(hc, hr, 0, -6)
    cylinder(beak, tup(p - n * 0.05), tup(p + n * 0.26 + Vector((0, -0.08, 0))), 0.12, segments=8, radius_b=0.02)
    _face(m, hc, hr, eye_yaw=32, eye_pitch=14, eye_size=0.13, mouth=False)
    crest = m.piece("HeadCrest", SUN_GLOW, material="Neon")
    for k, (ang, h) in enumerate(((-30, 0.42), (0, 0.55), (30, 0.42))):
        a = math.radians(ang)
        plate(crest, [(-0.08, 0), (0.08, 0), (0.03, h * 0.8), (0, h)], (0, 1.78, -0.12 + 0.08 * k), (1, 0, 0), (0, math.cos(a), math.sin(a)), 0.07)
    wing_outline = [(-0.05, 0.0), (0.3, 0.32), (0.62, 0.62), (0.95, 0.75), (0.8, 0.5), (1.05, 0.42), (0.82, 0.25),
                    (0.98, 0.08), (0.7, 0.02), (0.75, -0.16), (0.45, -0.06), (0.2, -0.16)]
    for side, name in ((-1, "WingL"), (1, "WingR")):
        wing = m.piece(name, (255, 86, 60), material=MAT)
        shoulder = (side * 0.36, 0.95, 0.1)
        _wing_plate(wing, wing_outline, shoulder, side, back=0.55, lift=0.25, thick=0.09)
        m.joints[name] = shoulder
    tail = m.piece("Tail", YELLOW, material=MAT)
    for k, yaw in enumerate((-22, 0, 22)):
        a = math.radians(yaw)
        feather = [(-0.1, 0), (0.1, 0), (0.16, 0.5), (0.08, 0.8), (0.0, 0.95), (-0.08, 0.8), (-0.16, 0.5)]
        plate(tail, feather, (0, 0.62, 0.62), (math.cos(a), 0, math.sin(a)), (math.sin(a) * 0.9, -0.5, 0.9), 0.07)
    m.joints["Tail"] = (0, 0.62, 0.6)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    p, n = surface(bc, br_, 0, -5)
    star(glow, tup(p + n * 0.03), 0.18, 0.06, normal=tup(n))
    for sx in (-1, 1):  # little talons (Body colour: keeps the phoenix at 10 pieces)
        tube(body, [(sx * 0.18, 0.28, 0.1), (sx * 0.2, 0.05, -0.02)], 0.05, sides=5)
        for k in (-1, 0, 1):
            ellipsoid(body, (sx * 0.2 + k * 0.06, 0.04, -0.1), (0.04, 0.04, 0.1), rings=3, segments=6)
    return _done(m)


def build_reactor_rex():
    """Reactor Rex: chubby baby dino, tiny arms, Neon back plates, a gold toy crown with a gem."""
    m = _pet("ReactorRex", "Legendary")
    green = (126, 204, 84)
    body = m.piece("Body", green, material=MAT)
    bc, br_ = (0, 0.78, 0.18), (0.58, 0.68, 0.6)
    _blob(body, bc, br_)
    for sx in (-1, 1):  # legs + tiny arms
        ellipsoid(body, (sx * 0.34, 0.22, 0.12), (0.22, 0.24, 0.26), rings=6, segments=10)
        tube(body, [(sx * 0.42, 0.92, -0.25), (sx * 0.46, 0.8, -0.48)], 0.07, sides=6)
    belly = m.piece("Belly", YELLOW, material=MAT)
    p, n = surface(bc, br_, 0, -10)
    oriented_ellipsoid(belly, tup(p - n * 0.1), (0.38, 0.48, 0.14), normal=tup(n), rings=6, segments=10)
    head = m.piece("Head", green, material=MAT)
    hc, hr = (0, 1.62, -0.32), (0.58, 0.5, 0.62)
    _blob(head, hc, hr, rings=10, segments=16)
    m.joints["Head"] = (0, 1.28, -0.12)
    _face(m, hc, hr, eye_yaw=34, eye_pitch=18, eye_size=0.14, mouth_pitch=-18, mouth_w=30)
    crown_p = m.piece("HeadCrown", GOLD, material=MAT)
    gem = m.piece("HeadGem", TOY_RED, material="Smooth")
    crown(crown_p, gem, (0, 2.0, -0.25), 0.3, 0.36, points=5, segments=16)
    tail = m.piece("Tail", green, material=MAT)
    _tail(tail, [(0, 0.6, 0.62), (0.05, 0.45, 1.0), (-0.05, 0.3, 1.35)], 0.26, 0.07)
    m.joints["Tail"] = (0, 0.6, 0.66)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    for i, (y, z) in enumerate(((1.35, 0.55), (1.0, 0.75), (0.65, 0.82))):
        h = 0.3 - 0.05 * i
        plate(glow, [(-0.14, 0), (0.14, 0), (0.08, h * 0.8), (0, h), (-0.08, h * 0.8)], (0, y, z), (1, 0, 0), (0, 0.6, 1), 0.08)
    _orbit(m, (0, 1.1, 0.1), 1.09, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


# ------------------------------------------------------------------------------------------------
# MYTHIC
# ------------------------------------------------------------------------------------------------


def build_core_dragon():
    """Core Dragon: purple baby dragon, glowing green belly core + spikes, gold horns, bat wings."""
    m = _pet("CoreDragon", "Mythic", hover=0.9)
    body = m.piece("Body", PURPLE, material=MAT)
    bc, br_ = (0, 0.72, 0.15), (0.55, 0.62, 0.62)
    _blob(body, bc, br_)
    for sx in (-1, 1):
        ellipsoid(body, (sx * 0.32, 0.2, 0.15), (0.2, 0.2, 0.24), rings=6, segments=10)
    glow = m.piece("Glow", GLOW_GREEN, material="Neon")
    p, n = surface(bc, br_, 0, -8)
    oriented_ellipsoid(glow, tup(p - n * 0.09), (0.34, 0.42, 0.13), normal=tup(n), rings=6, segments=10)
    for i, (y, z) in enumerate(((1.3, 0.38), (1.08, 0.65), (0.78, 0.78))):
        h = 0.24 - 0.03 * i
        plate(glow, [(-0.11, 0), (0.11, 0), (0, h)], (0, y, z), (1, 0, 0), (0, 0.7, 0.8), 0.07)
    head = m.piece("Head", PURPLE, material=MAT)
    hc, hr = (0, 1.5, -0.25), (0.6, 0.52, 0.56)
    _blob(head, hc, hr, rings=10, segments=16)
    p, n = surface(hc, hr, 0, -18)
    ellipsoid(head, tup(p - n * 0.05), (0.32, 0.2, 0.22), rings=6, segments=10)  # snout
    m.joints["Head"] = (0, 1.15, -0.08)
    _face(m, hc, hr, eye_yaw=30, eye_pitch=12, eye_size=0.15, mouth_pitch=-26, mouth_w=16)
    horns = m.piece("HeadHorns", GOLD, material=MAT)
    for side in (-1, 1):
        base, _ = surface(hc, hr, side * 34, 50)
        _tail(horns, [tup(base - Vector((0, 0.06, 0))), tup(base + Vector((side * 0.1, 0.22, 0.12))), tup(base + Vector((side * 0.14, 0.36, 0.3)))], 0.09, 0.03, sides=6, per=3)
    wing_outline = [(-0.05, -0.05), (0.15, 0.4), (0.55, 0.85), (0.62, 0.55), (0.82, 0.62), (0.88, 0.3), (1.05, 0.28),
                    (0.95, 0.0), (0.6, 0.08), (0.3, -0.08)]
    for side, name in ((-1, "WingL"), (1, "WingR")):
        wing = m.piece(name, LAVENDER, material=MAT)
        shoulder = (side * 0.34, 1.05, 0.38)
        _wing_plate(wing, wing_outline, shoulder, side, back=0.7, lift=0.3, thick=0.08)
        m.joints[name] = shoulder
    tail = m.piece("Tail", PURPLE, material=MAT)
    pts = _tail(tail, [(0, 0.5, 0.65), (0.15, 0.35, 1.0), (0.0, 0.3, 1.35)], 0.2, 0.06, tip=False)
    end = v3(pts[-1])
    plate(tail, [(-0.18, 0.0), (0.0, -0.1), (0.18, 0.0), (0.0, 0.3)], tup(end + Vector((0, 0, 0.05))), (0, 1, 0), (0, 0, 1), 0.07)
    m.joints["Tail"] = (0, 0.5, 0.68)
    _orbit(m, (0, 1.1, 0.1), 1.13, color=SUN_GLOW, rings=((0.0, 0.0),), electrons=2)
    return _done(m)


def build_nova_unicorn():
    """Nova Unicorn: white pony, pink mane + tail, gold hooves, Neon star horn, star mark, halo."""
    m = _pet("NovaUnicorn", "Mythic")
    hooves = m.piece("Hooves", GOLD, material=MAT)
    body, head, bc, br_, hc, hr = _std_quadruped(m, SNOW, body_c=(0, 0.86, 0.2), body_r=(0.55, 0.52, 0.72), head_c=(0, 1.6, -0.36), head_r=(0.6, 0.55, 0.55), leg_piece=None, leg_r=0.16)
    for sx in (-1, 1):
        for sz in (-1, 1):
            ellipsoid(hooves, (sx * 0.3, 0.07, 0.2 + sz * 0.4), (0.18, 0.08, 0.19), rings=4, segments=10)
    for side in (-1, 1):
        _ear_tri(head, None, hc, hr, side, yaw=44, pitch=44, w=0.14, h=0.3, lean=18, thick=0.1)
    mane = m.piece("HeadMane", HOT_PINK, material=MAT)
    for yaw, pitch in ((0, 60), (180, 82), (180, 50), (180, 18)):
        q, nq = surface(hc, hr, yaw, pitch)
        ellipsoid(mane, tup(q - nq * 0.04), (0.15, 0.17, 0.16), rings=4, segments=8)  # forelock + crest
    for k in range(3):  # mane flowing down the neck
        ellipsoid(mane, (0.02 * (k % 2), 1.2 - 0.12 * k, 0.12 + 0.12 * k), (0.14, 0.16, 0.15), rings=4, segments=8)
    horn = m.piece("HeadHorn", SUN_GLOW, material="Neon")
    base, n = surface(hc, hr, 0, 52)
    _horn(horn, tup(base - n * 0.05), tup(base + Vector((0, 0.52, -0.22))), 0.11, turns=3)
    face, sh = _face(m, hc, hr, eye_yaw=30, eye_pitch=6, eye_size=0.15, mouth_pitch=-24, mouth_w=12)
    for side in (-1, 1):  # lashes
        p, n2 = surface(hc, hr, side * 38, 18)
        plate(face, [(-0.03, 0), (0.03, 0), (side * 0.06, 0.1)], tup(p), tup(n2), (side * 0.6, 1, 0), 0.03)
    tail = m.piece("Tail", HOT_PINK, material=MAT)
    _tail(tail, [(0, 1.1, 0.85), (0.1, 1.0, 1.15), (-0.05, 0.62, 1.3), (0.08, 0.35, 1.22)], 0.17, 0.12, sides=6)
    m.joints["Tail"] = (0, 1.08, 0.84)
    glow = m.piece("Glow", MAGENTA, material="Neon")
    for side in (-1, 1):
        p, n2 = surface(bc, br_, side * 110, 12)
        star(glow, tup(p + n2 * 0.02), 0.16, 0.05, normal=tup(n2))
    _orbit(m, (0, 2.3, -0.2), 0.42, color=SUN_GLOW, rings=((8.0, 0.0),), electrons=0, thickness=0.06)
    m.joints["Orbit"] = (0, 2.3, -0.2)
    return _done(m)


def build_ion_jelly():
    """Ion Jelly: floating glass jellyfish bell, Neon core, wavy lavender tentacles, halo ring."""
    m = _pet("IonJelly", "Mythic", hover=1.0)
    bell = m.piece("Body", SKY_GLOW, material="Glass", transparency=0.35)
    revolve(bell, [(0.0, 2.05), (0.42, 2.0), (0.72, 1.8), (0.86, 1.48), (0.86, 1.22), (0.7, 1.16), (0.0, 1.3)], center=(0, 0, 0), segments=18)
    for i in range(10):  # scalloped rim
        a = 2 * math.pi * i / 10
        ellipsoid(bell, (math.cos(a) * 0.82, 1.18, math.sin(a) * 0.82), (0.14, 0.09, 0.14), rings=4, segments=8)
    core = m.piece("Glow", MAGENTA, material="Neon")
    ellipsoid(core, (0, 1.58, 0.05), (0.34, 0.26, 0.34), rings=6, segments=10)
    hc, hr = (0, 1.6, 0), (0.86, 0.48, 0.86)
    _face(m, hc, hr, prefix="", eye_yaw=22, eye_pitch=-6, eye_size=0.13, mouth_pitch=-26, mouth_w=12)
    tent = m.piece("Tail", LAVENDER, material=MAT)
    for i in range(6):
        a = 2 * math.pi * i / 6 + 0.5
        r0 = 0.5
        ctrl = []
        for k in range(5):
            f = k / 4
            wob = 0.1 * math.sin(f * 6 + i)
            ctrl.append((math.cos(a) * (r0 + wob), 1.22 - f * 1.18, math.sin(a) * (r0 + wob)))
        _tail(tent, ctrl, 0.07, 0.04, sides=5, per=3)
    m.joints["Tail"] = (0, 1.2, 0)
    _orbit(m, (0, 2.3, 0), 0.5, color=SUN_GLOW, rings=((0.0, 0.0),), electrons=0, thickness=0.06)
    return _done(m)


# ------------------------------------------------------------------------------------------------
# SECRET
# ------------------------------------------------------------------------------------------------


def build_golden_nukey():
    """Golden Nukey: the all-gold mascot nuke come alive: face, stubby arms, crown, two Neon rings."""
    m = _pet("GoldenNukey", "Secret")
    body = m.piece("Body", GOLD, material=MAT)
    nose = m.piece("Nose", SNOW, material=MAT)
    fins = m.piece("Fins", GOLD_DARK, material=MAT)
    core = m.piece("Glow", GLOW_GREEN, material="Neon")
    radius = 0.62
    nuke_body(body, nose, fins, core, base=(0, 0, 0), length=2.4, radius=radius, segments=16)
    for sx in (-1, 1):
        ellipsoid(body, (sx * 0.68, 1.0, -0.05), (0.16, 0.24, 0.16), rings=5, segments=8)
    fc, fr = (0, 1.3, 0), (radius, 1.6, radius)
    _face(m, fc, fr, prefix="", eye_yaw=26, eye_pitch=2, eye_size=0.15, mouth_pitch=-6, mouth_w=16)
    band = m.piece("Crown", GOLD, material="Smooth")
    gems = m.piece("CrownGems", HOT_PINK, material="Smooth")
    crown(band, gems, (0, 2.0, 0), 0.4, 0.42, points=5, segments=16)
    _orbit(m, (0, 1.2, 0), 1.05, color=GLOW_GREEN, rings=((-22.0, -18.0), (-12.0, 34.0)))
    return _done(m)


def build_void_cat():
    """Void Cat: dark-matter kitty, glowing cyan eyes, starry Neon specks, galaxy ring + halo."""
    m = _pet("VoidCat", "Secret", hover=0.3)
    void = (44, 34, 84)
    body, head, bc, br_, hc, hr = _std_quadruped(m, void, head_r=(0.72, 0.58, 0.58))
    inner = m.piece("HeadAccent", LAVENDER, material="Smooth")
    for side in (-1, 1):
        _ear_tri(head, inner, hc, hr, side, yaw=36, pitch=46, w=0.25, h=0.5, lean=16)
    face = m.piece("HeadFace", SKY_GLOW, material="Neon")
    eyes(face, None, hc, hr, yaw=26, pitch=6, size=0.16, tall=1.3)
    p, n = surface(hc, hr, 0, -8)
    oriented_ellipsoid(inner, tup(p), (0.07, 0.05, 0.04), normal=tup(n), rings=4, segments=8)
    smile(inner, hc, hr, pitch=-18, width=9)
    glow = m.piece("Glow", (230, 210, 255), material="Neon")
    for yaw, pitch, s in ((120, 30, 0.12), (-110, 40, 0.1), (160, 20, 0.09), (-150, 10, 0.11), (80, 5, 0.08)):
        p, n = surface(bc, br_, yaw, pitch)
        star(glow, tup(p + n * 0.02), s, 0.04, normal=tup(n))
    tail = m.piece("Tail", void, material=MAT)
    _tail(tail, [(0, 0.75, 0.72), (0.1, 0.95, 1.0), (-0.05, 1.35, 1.1), (0.15, 1.6, 1.0)], 0.09, 0.07)
    m.joints["Tail"] = (0, 0.76, 0.74)
    orbit = _orbit(m, (0, 1.05, 0.0), 1.05, color=MAGENTA, rings=((-22.0, -18.0), (-12.0, 34.0)))
    orbit_ring(orbit, (0, 2.25, -0.3), 0.36, 0.05, segments=20, sides=5)  # halo rides with the rings
    return _done(m)


# ------------------------------------------------------------------------------------------------
# GROUP-EXCLUSIVE + EVENT
# ------------------------------------------------------------------------------------------------


def build_builder_beaver():
    """Builder Beaver (group reward): beaver in a hazard-yellow hard hat, buck teeth, paddle tail."""
    m = _pet("BuilderBeaver", "Group")
    brown = (160, 102, 64)
    body, head, bc, br_, hc, hr = _std_quadruped(m, brown, body_c=(0, 0.7, 0.18), body_r=(0.62, 0.56, 0.68), head_r=(0.68, 0.58, 0.58))
    belly = m.piece("Belly", (230, 190, 140), material=MAT)
    oriented_ellipsoid(belly, (0, 0.66, -0.38), (0.38, 0.36, 0.12), normal=(0, -0.1, -1), rings=6, segments=10)
    muzzle = m.piece("HeadMuzzle", (230, 190, 140), material=MAT)
    mc, mr = _muzzle(muzzle, hc, hr, size=(0.3, 0.2, 0.2), pitch=-16)
    for side in (-1, 1):
        _ear_round(head, None, hc, hr, side, yaw=62, pitch=36, r=0.14)
    face, _ = _face(m, hc, hr, prefix="Head", eye_yaw=27, eye_pitch=10, eye_size=0.14, mouth=False)
    _nose(face, mc, mr, pitch=34, size=(0.11, 0.08, 0.08))
    whites = m.pieces["HeadShine"]
    p, n = surface(mc, mr, 0, -38)
    for sx in (-1, 1):
        oriented_ellipsoid(whites, tup(p + n * 0.02 + Vector((sx * 0.055, -0.07, 0))), (0.05, 0.09, 0.03), normal=tup(n), rings=4, segments=8)
    hat = m.piece("HeadHat", HAZARD_YELLOW, material=MAT)
    revolve(hat, [(0.0, 2.22), (0.38, 2.18), (0.56, 1.98), (0.6, 1.84), (0.78, 1.82), (0.78, 1.76), (0.0, 1.76)], center=(0, 0, -0.3), segments=16)
    tube(hat, [(0, 2.2, -0.3), (0, 2.2 - 0.02, -0.3 - 0.4)], 0.07, sides=6)  # ridge
    glow = m.piece("HeadGlow", GLOW_GREEN, material="Neon")
    p, n = surface((0, 1.98, -0.3), (0.58, 0.22, 0.58), 0, 8)
    _glow_badge(glow, tup(p), tup(n), radius=0.12)
    tail = m.piece("Tail", (96, 64, 48), material=MAT)
    oriented_ellipsoid(tail, (0, 0.2, 1.05), (0.34, 0.08, 0.46), normal=(0, 1, 0.25), up=(0, 0, 1), rings=5, segments=12)
    m.joints["Tail"] = (0, 0.3, 0.75)
    return _done(m)


def build_gobble_bomb():
    """
    Gobble Bomb (Harvest Feast sticker-sheet reward): a round cartoon TOY bomb dressed as a turkey —
    fan of candy feathers behind, little turkey head with beak + wattle, candy fuse with a Neon spark.
    """
    m = _pet("GobbleBomb", "Event")
    body = m.piece("Body", TURKEY_BROWN, material=MAT)
    bc, br_ = (0, 1.02, 0.05), (0.8, 0.8, 0.78)
    _blob(body, bc, br_, rings=10, segments=16)
    band = m.piece("Band", BURNT_ORANGE, material=MAT)
    revolve(band, [(0.81, -0.1), (0.86, -0.06), (0.86, 0.06), (0.81, 0.1)], center=(0, 0.84, 0.05), segments=18, closed=True)
    tube(band, [(0, 1.76, 0.12), (0.05, 1.92, 0.16), (0.14, 2.04, 0.12)], 0.06, sides=6)  # candy fuse
    for sx in (-1, 1):  # orange turkey legs + three-toed feet (the bomb stands on them)
        tube(band, [(sx * 0.3, 0.3, -0.1), (sx * 0.32, 0.06, -0.2)], 0.06, sides=5)
        for k in (-1, 0, 1):
            ellipsoid(band, (sx * 0.32 + k * 0.08, 0.045, -0.3 - abs(k) * 0.02), (0.05, 0.045, 0.15), rings=3, segments=6)
    head = m.piece("Head", (196, 138, 92), material=MAT)
    hc, hr = (0, 1.62, -0.6), (0.36, 0.38, 0.34)
    _blob(head, hc, hr, rings=8, segments=14)
    m.joints["Head"] = (0, 1.4, -0.42)
    beak = m.piece("HeadBeak", YELLOW, material="Smooth")
    p, n = surface(hc, hr, 0, -4)
    cylinder(beak, tup(p - n * 0.04), tup(p + n * 0.18 + Vector((0, -0.04, 0))), 0.08, segments=8, radius_b=0.015)
    wattle = m.piece("HeadWattle", WATTLE_RED, material="Smooth")
    ellipsoid(wattle, tup(p + Vector((0.04, -0.14, -0.05))), (0.06, 0.12, 0.06), rings=5, segments=8)
    _face(m, hc, hr, eye_yaw=34, eye_pitch=14, eye_size=0.09, mouth=False)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    star(glow, (0.14, 2.1, 0.12), 0.14, 0.06, normal=(0, 0, -1))
    trefoil(glow, (0, 1.02, -0.82), 0.2, 0.05, normal=(0, -0.05, -1))
    tail_a = m.piece("Tail", BURNT_ORANGE, material=MAT)
    tail_b = m.piece("TailB", YELLOW, material=MAT)
    for k in range(9):
        ang = math.radians(-76 + 19 * k)
        up = (math.sin(ang), math.cos(ang), 0.0)
        piece = tail_a if k % 2 == 0 else tail_b
        z = 0.62 + (0.02 if k % 2 else 0.0)
        feather = [(-0.17, 0), (0.17, 0), (0.22, 0.7), (0.14, 0.95), (0.0, 1.05), (-0.14, 0.95), (-0.22, 0.7)]
        plate(piece, feather, (math.sin(ang) * 0.35, 1.12 + math.cos(ang) * 0.35, z), (0, 0, 1), up, 0.07)
    m.joints["Tail"] = (0, 1.12, 0.6)
    return _done(m)


def build_acorn_squirrel():
    """Acorn Squirrel (Harvest Egg): russet squirrel, huge curled tail, hugging a glowing gold acorn."""
    m = _pet("AcornSquirrel", "Harvest")
    russet = (206, 112, 58)
    body, head, bc, br_, hc, hr = _std_quadruped(m, russet, body_c=(0, 0.66, 0.15), body_r=(0.5, 0.56, 0.56), head_c=(0, 1.36, -0.2), head_r=(0.6, 0.54, 0.54))
    cream = m.piece("HeadAccent", CREAM, material=MAT)
    for side in (-1, 1):
        _ear_tri(head, cream, hc, hr, side, yaw=32, pitch=50, w=0.18, h=0.36, lean=10)
    mc, mr = _muzzle(cream, hc, hr, size=(0.24, 0.17, 0.18), pitch=-18)
    face, _ = _face(m, hc, hr, eye_yaw=28, eye_pitch=8, eye_size=0.15, mouth=False)
    _nose(face, mc, mr, pitch=34, size=(0.07, 0.05, 0.05))
    smile(face, mc, mr, pitch=-24, width=20, depth=8, thickness=0.026)
    belly = m.piece("Belly", CREAM, material=MAT)
    oriented_ellipsoid(belly, (0, 0.64, -0.3), (0.3, 0.36, 0.12), normal=(0, -0.1, -1), rings=6, segments=10)
    tail = m.piece("Tail", russet, material=MAT)
    _tail(tail, [(0, 0.5, 0.6), (0, 0.8, 1.0), (0, 1.4, 1.05), (0, 1.85, 0.75), (0, 1.75, 0.45)], 0.18, 0.28, sides=8)
    m.joints["Tail"] = (0, 0.55, 0.6)
    glow = m.piece("Glow", SUN_GLOW, material="Neon")
    ellipsoid(glow, (0, 0.58, -0.62), (0.2, 0.24, 0.2), rings=6, segments=10)
    cap = m.piece("AcornCap", WOOD_DARK, material=MAT)
    ellipsoid(cap, (0, 0.78, -0.62), (0.23, 0.11, 0.23), rings=5, segments=10)
    tube(cap, [(0, 0.86, -0.62), (0.04, 0.96, -0.64)], 0.035, sides=5)
    return _done(m)


def build_harvest_hedgehog():
    """Harvest Hedgehog (Harvest Egg): tan hedgehog, chunky brown spikes, an autumn leaf + Neon berries."""
    m = _pet("HarvestHedgehog", "Harvest")
    tan = (232, 196, 150)
    body = m.piece("Body", tan, material=MAT)
    bc, br_ = (0, 0.66, 0.12), (0.7, 0.62, 0.72)
    _blob(body, bc, br_)
    _legs(body, bc, br_, leg_r=0.15)
    p, n = surface(bc, br_, 0, -8)
    ellipsoid(body, tup(p + n * 0.12 + Vector((0, -0.06, 0))), (0.22, 0.16, 0.24), rings=6, segments=10)  # snout
    hc, hr = bc, br_
    face, _ = _face(m, hc, hr, prefix="", eye_yaw=22, eye_pitch=8, eye_size=0.13, mouth=False)
    nose_p = p + n * 0.36 + Vector((0, -0.04, 0))
    ellipsoid(face, tup(nose_p), (0.07, 0.06, 0.06), rings=4, segments=8)
    smile(face, hc, hr, pitch=-24, width=10)
    spikes = m.piece("Spikes", CHOCOLATE, material=MAT)
    for ring_i, pitch in enumerate((70, 48, 26, 6, -14)):
        count = 4 + ring_i * 2
        for k in range(count):
            yaw = 180 - 100 + 200 * (k + 0.5 * (ring_i % 2)) / count
            if pitch < 20 and abs(((yaw + 180) % 360) - 180) < 60:
                continue  # keep the face clear
            q, nq = surface(bc, br_, yaw, pitch)
            cylinder(spikes, tup(q - nq * 0.08), tup(q + nq * 0.3), 0.11, segments=5, radius_b=0.015)
    leaf = m.piece("Leaf", BURNT_ORANGE, material="Smooth")
    q, nq = surface(bc, br_, 160, 40)
    leaf_outline = [(0, -0.05), (0.14, 0.08), (0.28, 0.06), (0.22, 0.2), (0.3, 0.32), (0.12, 0.3), (0.0, 0.46),
                    (-0.12, 0.3), (-0.3, 0.32), (-0.22, 0.2), (-0.28, 0.06), (-0.14, 0.08)]
    plate(leaf, leaf_outline, tup(q + nq * 0.3), tup(nq), (0, 0.3, 1), 0.04)
    glow = m.piece("Glow", WATTLE_RED, material="Neon")
    for k in range(3):
        ellipsoid(glow, tup(q + nq * 0.38 + Vector((0.12 * (k - 1), 0.05 * (k % 2), -0.1))), (0.07, 0.07, 0.07), rings=4, segments=8)
    return _done(m)


def build_cranberry_crab():
    """Cranberry Crab (Harvest Egg): round cranberry-red crab, waving claws, stalk eyes, leaf hat."""
    m = _pet("CranberryCrab", "Harvest")
    cran = (206, 40, 74)
    body = m.piece("Body", cran, material=MAT)
    bc, br_ = (0, 0.55, 0.05), (0.82, 0.42, 0.62)
    _blob(body, bc, br_)
    for sx in (-1, 1):
        for k in range(3):  # three bent legs per side
            z = -0.15 + 0.3 * k
            tube(body, [(sx * 0.6, 0.45, z), (sx * 0.9, 0.42, z + 0.04), (sx * 0.98, 0.08, z + 0.08)], 0.09, sides=6)
            ellipsoid(body, (sx * 0.98, 0.07, z + 0.08), (0.1, 0.07, 0.1), rings=4, segments=6)
        tube(body, [(sx * 0.2, 0.9, -0.3), (sx * 0.24, 1.25, -0.36)], 0.08, sides=6)  # eye stalks
    face = m.piece("Face", SOFT_BLACK, material="Smooth")
    shine = m.piece("Shine", SNOW, material="Smooth")
    for sx in (-1, 1):
        ec = Vector((sx * 0.24, 1.33, -0.38))
        ellipsoid(face, tup(ec), (0.13, 0.15, 0.13), rings=6, segments=10)
        ellipsoid(shine, tup(ec + Vector((-sx * 0.04, 0.06, -0.11))), (0.04, 0.04, 0.03), rings=3, segments=6)
    smile(face, bc, br_, pitch=-2, width=16, depth=6)
    for side, name in ((-1, "ClawL"), (1, "ClawR")):
        claw = m.piece(name, (232, 70, 96), material=MAT)
        shoulder = Vector((side * 0.62, 0.6, -0.35))
        elbow = Vector((side * 0.9, 0.9, -0.6))
        tube(claw, [tup(shoulder), tup(elbow)], 0.09, sides=6)
        oriented_ellipsoid(claw, tup(elbow + Vector((side * 0.04, 0.22, -0.08))), (0.24, 0.3, 0.15), normal=(side, 0, -0.4), rings=6, segments=10)
        oriented_ellipsoid(claw, tup(elbow + Vector((side * 0.12, 0.48, -0.12))), (0.08, 0.16, 0.08), normal=(side, 0, -0.4), up=(side * 0.6, 1, 0), rings=5, segments=8)
        m.joints[name] = tup(shoulder)
    leaf = m.piece("Leaf", LEAF, material="Smooth")
    plate(leaf, [(0, 0), (0.12, 0.1), (0.2, 0.3), (0.0, 0.42), (-0.2, 0.3), (-0.12, 0.1)], (0.0, 0.94, 0.15), (0, 0.3, 1), (0.4, 1, 0), 0.04)
    glow = m.piece("Glow", (255, 120, 150), material="Neon")
    _spots(glow, bc, br_, [(130, 30), (-130, 30), (180, 45, 0.8), (100, 50, 0.7), (-100, 50, 0.7)], size=0.1)
    return _done(m)


BUILDERS = {
    "GlowSlime": build_glow_slime,
    "AtomPup": build_atom_pup,
    "IsotopeKitty": build_isotope_kitty,
    "QuarkDuck": build_quark_duck,
    "UraniumBunny": build_uranium_bunny,
    "NeutronNewt": build_neutron_newt,
    "PlasmaPig": build_plasma_pig,
    "MegaMole": build_mega_mole,
    "FissionFox": build_fission_fox,
    "ReactorOwl": build_reactor_owl,
    "ProtonPanda": build_proton_panda,
    "GammaGator": build_gamma_gator,
    "NuclearNarwhal": build_nuclear_narwhal,
    "CosmicCorgi": build_cosmic_corgi,
    "RadRaccoon": build_rad_raccoon,
    "AtomicAxolotl": build_atomic_axolotl,
    "MeltdownMoose": build_meltdown_moose,
    "FusionPhoenix": build_fusion_phoenix,
    "ReactorRex": build_reactor_rex,
    "CoreDragon": build_core_dragon,
    "NovaUnicorn": build_nova_unicorn,
    "IonJelly": build_ion_jelly,
    "GoldenNukey": build_golden_nukey,
    "VoidCat": build_void_cat,
    "BuilderBeaver": build_builder_beaver,
    "GobbleBomb": build_gobble_bomb,
    "AcornSquirrel": build_acorn_squirrel,
    "HarvestHedgehog": build_harvest_hedgehog,
    "CranberryCrab": build_cranberry_crab,
}
