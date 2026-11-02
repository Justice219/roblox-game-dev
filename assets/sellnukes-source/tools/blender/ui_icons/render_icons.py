"""
render_icons.py — original Blender renders for the SellNukes 3D UI icons (owner R9: "make sure we
do like the 3D icons ... rendered instead of like flat ... they look 3D").

Purpose:
    Most icons come from Microsoft Fluent Emoji 3D (MIT; see tools/ui/icons/icons.py). Every icon no
    emoji covers well — the cartoon pocket nuke, the "31" calendar, the colour wheel, the red shop
    basket, the green money stack, the acorn, the rebirth arrows, the treasure chest, the potion,
    the supply crate, the AA tower, the cooling-tower facility, the Dino Valley set (fossil bones,
    amber, bone heaps, dino head, Time Machine, pocket-watch, ptero egg), the Moon Base set (moon
    rocks + heaps, star shards, smiling moon tab, moon rocket portal, corgi bubble helmet) and the
    Lucky Button, ... — is built here as real
    geometry and rendered in ONE shared style so it sits next to the emoji without looking foreign:

        * soft-toon emission material: diffuse luminance x crease AO through an eased 3-tone ramp
          (violet-shifted shadow -> base -> warm light), a gentle facing-ratio edge darkening for
          volume and a crisp white specular blob (the glossy "simulator icon" look);
        * one key sun light (no cast shadows: cleaner toon read), high front-left;
        * an orthographic 3/4 camera (front-right, slightly above) auto-framed to the same box as
          the pack icons;
        * thin inverted-hull inner lines between parts (the thick OUTER outline is added in post by
          tools/ui/icons/icons.py with an exact disc dilation, identical for pack + Blender icons).

How it connects:
    - Run by `python3 tools/ui/icons/icons.py render` (which owns post-processing, the contact sheet,
      upload and the generated src/shared/Config/IconAssets.luau). Raw 2048 x 2048 RGBA renders land
      in <out_dir>/<Name>.png. Names starting with "_" are composite PARTS (never uploaded alone).
    - Colours follow the SellNukes toy palette (tools/blender/snkit/core.py) so icons match the
      world models built by B4 (e.g. the PocketNuke: red body, white nose, charcoal fins, glowing
      green core band, yellow trefoil badge).
    - Nothing in the game loads this file.

Usage (deterministic geometry, no randomness):
    blender --background --factory-startup --python-exit-code 1 \
        --python tools/blender/ui_icons/render_icons.py -- <out_dir> [Name ...]

Coordinates: Z is up, the viewer looks from -Y (front), the camera sits front-RIGHT and above.
Dimensions are arbitrary units: framing normalises every icon to the same pixel box.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

# ---------------------------------------------------------------------------------------------
# Render / framing constants (must agree with tools/ui/icons/icons.py)
# ---------------------------------------------------------------------------------------------

# The raw pass is 2048 px; the post-process downsamples 4:1 to 512 px (16x supersampled edges).
RENDER_SIZE = 2048
FINAL_SIZE = 512
# Final-pixel budget per side: outer outline (post) + hull line + breathing room. Geometry (without
# the hull) is framed to fill FINAL_SIZE - 2 * (OUTLINE_PX + HULL_PX + PAD_PX) on its longer side,
# so geometry + hull fills exactly the pack icons' box of FINAL_SIZE - 2 * (OUTLINE_PX + PAD_PX).
OUTLINE_PX = 18
HULL_PX = 5
PAD_PX = 6
# Default camera: 3/4 view from the front-right, a little from above (the reference icons' angle).
DEFAULT_YAW = 28.0
DEFAULT_PITCH = 20.0
# Key light: high front-left, so lit sides face the HUD's top-left (matches Fluent Emoji 3D).
LIGHT_DIRECTION = Vector((-0.55, -0.75, 0.9))
# Inner hull lines use the HUD text-stroke colour (UIStyleConfig TextStroke 20,20,28).
OUTLINE_RGB = (20, 20, 28)
# Crease shading reach (world units; icons are ~2-3 units across) and strength (0..1).
AO_DISTANCE = 0.3
AO_STRENGTH = 0.8

# SellNukes toy palette (tools/blender/snkit/core.py) + a few icon-only accents.
WHITE = (244, 244, 248)
CREAM = (252, 242, 214)
TOY_RED = (232, 64, 56)
DARK_RED = (150, 30, 40)
ORANGE = (255, 146, 40)
YELLOW = (255, 214, 50)
GOLD = (255, 190, 40)
LIME = (120, 220, 60)
GREEN = (72, 196, 72)
CASH_GREEN = (92, 196, 88)
CASH_LIGHT = (150, 230, 130)
CASH_DARK = (34, 120, 52)
GLOW_GREEN = (110, 255, 90)
SKY_BLUE = (96, 168, 236)
DEEP_BLUE = (52, 104, 196)
NAVY = (40, 48, 96)
PURPLE = (150, 96, 220)
VIOLET = (170, 80, 235)
PINK = (255, 120, 180)
CYAN = (70, 210, 235)
WOOD = (214, 150, 86)
WOOD_DARK = (164, 104, 58)
BROWN = (130, 84, 50)
NUT = (212, 128, 60)
STEEL = (170, 178, 192)
DARK_STEEL = (92, 98, 112)
CHARCOAL = (58, 60, 70)
HAZARD_BLACK = (44, 44, 54)
CONCRETE = (214, 216, 226)
GLASS = (196, 236, 255)
GRASS = (98, 204, 70)


# ---------------------------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------------------------


def srgb_to_linear(channel):
    """sRGB (0..1) -> linear light (Blender shades in linear; Standard view round-trips exactly)."""
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def lin(rgb):
    """Linear RGBA tuple from a 0..255 sRGB triple. Example: lin((255, 0, 0)) -> (1, 0, 0, 1)."""
    return (srgb_to_linear(rgb[0] / 255), srgb_to_linear(rgb[1] / 255), srgb_to_linear(rgb[2] / 255), 1.0)


def mix_rgb(a, b, t):
    """Linear interpolation of two 0..255 colours (derives shadow / light tones)."""
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def tones(base, shadow=None, light=None):
    """
    The three toon tones of a base colour: shadows shift toward deep violet (never grey/black,
    which reads dirty), lights toward warm white — the saturated look of simulator HUD icons.
    """
    return (
        shadow or mix_rgb(base, (70, 30, 110), 0.42),
        base,
        light or mix_rgb(base, (255, 252, 235), 0.4),
    )


# ---------------------------------------------------------------------------------------------
# Materials (one shared soft-toon recipe; every surface is emission so colours are exact)
# ---------------------------------------------------------------------------------------------


def _ramp(nodes, links, source, stops, interpolation="EASE"):
    """A ColorRamp fed by `source` with `stops` = [(position, linear RGBA), ...]."""
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = interpolation
    elements = ramp.color_ramp.elements
    while len(elements) < len(stops):
        elements.new(0.5)
    for element, (position, color) in zip(elements, stops):
        element.position = position
        element.color = color
    links.new(source, ramp.inputs["Fac"])
    return ramp


def _lighting(nodes, links, bsdf_type, roughness=None):
    """Greyscale luminance of a white BSDF lit by the scene (Shader to RGB): the toon ramp input."""
    bsdf = nodes.new(bsdf_type)
    bsdf.inputs["Color"].default_value = (1, 1, 1, 1)
    if roughness is not None:
        bsdf.inputs["Roughness"].default_value = roughness
    to_rgb = nodes.new("ShaderNodeShaderToRGB")
    links.new(bsdf.outputs[0], to_rgb.inputs["Shader"])
    grey = nodes.new("ShaderNodeRGBToBW")
    links.new(to_rgb.outputs["Color"], grey.inputs["Color"])
    return grey.outputs["Val"]


def _creased(nodes, links, luminance):
    """Luminance x (AO x s + (1 - s)): contact shading in creases with no shadow-map acne."""
    occlusion = nodes.new("ShaderNodeAmbientOcclusion")
    occlusion.inputs["Distance"].default_value = AO_DISTANCE
    factor = nodes.new("ShaderNodeMath")
    factor.operation = "MULTIPLY_ADD"
    links.new(occlusion.outputs["AO"], factor.inputs[0])
    factor.inputs[1].default_value = AO_STRENGTH
    factor.inputs[2].default_value = 1 - AO_STRENGTH
    shaded = nodes.new("ShaderNodeMath")
    shaded.operation = "MULTIPLY"
    links.new(luminance, shaded.inputs[0])
    links.new(factor.outputs[0], shaded.inputs[1])
    return shaded.outputs[0]


def _mix(nodes, links, factor, a, b):
    """Mix colour a -> b by factor (each argument may be a socket or a constant)."""
    node = nodes.new("ShaderNodeMix")
    node.data_type = "RGBA"
    for socket, value in ((node.inputs["Factor"], factor), (node.inputs[6], a), (node.inputs[7], b)):
        if isinstance(value, bpy.types.NodeSocket):
            links.new(value, socket)
        else:
            socket.default_value = value
    return node.outputs[2]


_MATERIALS = {}


def _stud_disc(nodes, links, scale, offset):
    """1 inside the stud disc of a 2D stud grid on the object-space XZ plane (the front face)."""
    coords = nodes.new("ShaderNodeTexCoord")
    scaled = nodes.new("ShaderNodeVectorMath")
    scaled.operation = "MULTIPLY_ADD"
    links.new(coords.outputs["Object"], scaled.inputs[0])
    scaled.inputs[1].default_value = (scale, scale, scale)
    scaled.inputs[2].default_value = (offset[0], 0.0, offset[1])
    split = nodes.new("ShaderNodeSeparateXYZ")
    links.new(scaled.outputs[0], split.inputs[0])
    parts = []
    for axis in ("X", "Z"):
        fract = nodes.new("ShaderNodeMath")
        fract.operation = "FRACT"
        links.new(split.outputs[axis], fract.inputs[0])
        centred = nodes.new("ShaderNodeMath")
        centred.operation = "SUBTRACT"
        links.new(fract.outputs[0], centred.inputs[0])
        centred.inputs[1].default_value = 0.5
        parts.append(centred.outputs[0])
    joined = nodes.new("ShaderNodeCombineXYZ")
    links.new(parts[0], joined.inputs["X"])
    links.new(parts[1], joined.inputs["Z"])
    length = nodes.new("ShaderNodeVectorMath")
    length.operation = "LENGTH"
    links.new(joined.outputs[0], length.inputs[0])
    inside = nodes.new("ShaderNodeMath")
    inside.operation = "LESS_THAN"
    links.new(length.outputs["Value"], inside.inputs[0])
    inside.inputs[1].default_value = 0.3
    return inside.outputs[0]


def toon(base, shadow=None, light=None, gloss=0.85, spots=None, checker=None, rim=0.45, studs=None):
    """
    The shared soft-toon material (cached per argument set, so repeated parts share one material).

    Pipeline (all emission):
        diffuse luminance x AO -> eased ramp shadow / base / light   (soft gradient shading)
        optional object-space spots (egg) or checker (acorn cap scales)
        facing ratio -> darkening toward the silhouette                (volume)
        glossy luminance -> narrow ramp -> white specular blob         (gloss 0 disables)
    @param spots   {"color": rgb, "centers": [(x, y, z, r?)], "radius": r} painted patches
    @param checker (scale, strength): 3D checker darkening in object space
    @param studs   (scale, strength): embossed LEGO-style studs on the object-space XZ (front)
                   plane: a lighter disc per stud cell with a shadow crescent below-right
    Example: toon(TOY_RED, gloss=1.0)
    """
    key = (base, shadow, light, gloss, repr(spots), checker, rim, studs)
    if key in _MATERIALS:
        return _MATERIALS[key]
    mat = bpy.data.materials.new(f"Toon{len(_MATERIALS)}")
    if bpy.app.version < (5, 0, 0):  # Blender 5+ materials always use nodes (use_nodes is deprecated)
        mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")

    diffuse = _creased(nodes, links, _lighting(nodes, links, "ShaderNodeBsdfDiffuse"))
    shadow_c, base_c, light_c = tones(base, shadow, light)
    # Ramp positions are luminances of a white diffuse surface under the key light (tuned by eye:
    # the terminator sits a little past side-on, so most of the visible form reads lit).
    stops = [(0.04, lin(shadow_c)), (0.32, lin(base_c)), (0.8, lin(light_c))]
    body = _ramp(nodes, links, diffuse, stops).outputs["Color"]

    if spots is not None:
        spot_shadow, spot_base, spot_light = tones(spots["color"])
        spot_body = _ramp(
            nodes, links, diffuse, [(0.04, lin(spot_shadow)), (0.32, lin(spot_base)), (0.8, lin(spot_light))]
        ).outputs["Color"]
        coords = nodes.new("ShaderNodeTexCoord")
        mask = None
        for center in spots["centers"]:
            distance = nodes.new("ShaderNodeVectorMath")
            distance.operation = "DISTANCE"
            links.new(coords.outputs["Object"], distance.inputs[0])
            distance.inputs[1].default_value = center[:3]
            inside = nodes.new("ShaderNodeMath")
            inside.operation = "LESS_THAN"
            links.new(distance.outputs["Value"], inside.inputs[0])
            inside.inputs[1].default_value = center[3] if len(center) > 3 else spots["radius"]
            if mask is None:
                mask = inside.outputs[0]
            else:
                union = nodes.new("ShaderNodeMath")
                union.operation = "MAXIMUM"
                links.new(mask, union.inputs[0])
                links.new(inside.outputs[0], union.inputs[1])
                mask = union.outputs[0]
        body = _mix(nodes, links, mask, body, spot_body)

    if checker is not None:
        scale, strength = checker
        coords = nodes.new("ShaderNodeTexCoord")
        texture = nodes.new("ShaderNodeTexChecker")
        texture.inputs["Scale"].default_value = scale
        texture.inputs["Color1"].default_value = (1, 1, 1, 1)
        texture.inputs["Color2"].default_value = (0, 0, 0, 1)
        links.new(coords.outputs["Object"], texture.inputs["Vector"])
        amount = nodes.new("ShaderNodeMath")
        amount.operation = "MULTIPLY"
        links.new(texture.outputs["Fac"], amount.inputs[0])
        amount.inputs[1].default_value = strength
        body = _mix(nodes, links, amount.outputs[0], body, lin(shadow_c))

    if studs is not None:
        scale, strength = studs
        top = _stud_disc(nodes, links, scale, (0.0, 0.0))
        lower = _stud_disc(nodes, links, scale, (-0.07, 0.08))
        # Shadow crescent: inside the shifted disc but outside the stud top.
        outside = nodes.new("ShaderNodeMath")
        outside.operation = "SUBTRACT"
        outside.inputs[0].default_value = 1.0
        links.new(top, outside.inputs[1])
        crescent = nodes.new("ShaderNodeMath")
        crescent.operation = "MULTIPLY"
        links.new(lower, crescent.inputs[0])
        links.new(outside.outputs[0], crescent.inputs[1])
        crescent_amount = nodes.new("ShaderNodeMath")
        crescent_amount.operation = "MULTIPLY"
        links.new(crescent.outputs[0], crescent_amount.inputs[0])
        crescent_amount.inputs[1].default_value = strength
        top_amount = nodes.new("ShaderNodeMath")
        top_amount.operation = "MULTIPLY"
        links.new(top, top_amount.inputs[0])
        top_amount.inputs[1].default_value = strength * 0.45
        body = _mix(nodes, links, top_amount.outputs[0], body, lin(light_c))
        body = _mix(nodes, links, crescent_amount.outputs[0], body, lin(shadow_c))

    # Edge darkening: the facing ratio near the silhouette blends a little toward the shadow tone.
    weight = nodes.new("ShaderNodeLayerWeight")
    weight.inputs["Blend"].default_value = 0.4
    edge = _ramp(nodes, links, weight.outputs["Facing"], [(0.55, (0, 0, 0, 1)), (1.0, (rim, rim, rim, 1))], "LINEAR")
    body = _mix(nodes, links, edge.outputs["Color"], body, lin(shadow_c))

    # Specular blob: crisp-edged highlight (narrow linear ramp = slightly soft edge).
    if gloss > 0:
        glossy = _lighting(nodes, links, "ShaderNodeBsdfGlossy", roughness=0.16)
        spec = _ramp(nodes, links, glossy, [(0.42, (0, 0, 0, 1)), (0.5, (gloss, gloss, gloss, 1))], "LINEAR")
        body = _mix(nodes, links, spec.outputs["Color"], body, (1, 1, 1, 1))

    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Strength"].default_value = 1.0
    links.new(body, emission.inputs["Color"])
    links.new(emission.outputs[0], out.inputs["Surface"])
    _MATERIALS[key] = mat
    return mat


def glow(base, light=(235, 255, 220)):
    """A 'glowing' toon (neon cores, steam): bright shadow tone, near-white light, soft gloss."""
    return toon(base, shadow=mix_rgb(base, (40, 120, 60), 0.35), light=light, gloss=0.5, rim=0.25)


def outline_material():
    """Inverted-hull material: flat outline colour, back faces culled (draws only the line)."""
    if "Outline" in bpy.data.materials:
        return bpy.data.materials["Outline"]
    mat = bpy.data.materials.new("Outline")
    if bpy.app.version < (5, 0, 0):  # Blender 5+ materials always use nodes (use_nodes is deprecated)
        mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Color"].default_value = lin(OUTLINE_RGB)
    links.new(emission.outputs[0], out.inputs["Surface"])
    mat.use_backface_culling = True
    return mat


# ---------------------------------------------------------------------------------------------
# Geometry helpers (bmesh only: deterministic, no operator context)
# ---------------------------------------------------------------------------------------------


def _object(name, bm, material, smooth=True, sharp_angle=50.0, matrix=None):
    """
    Turns a bmesh into a linked object with `material` in slot 0. Faces are smooth-shaded with
    edges sharper than `sharp_angle` degrees split (Blender 4.1+ smooth-by-angle), so bevelled
    corners read round while true creases stay crisp. `matrix` is baked into the mesh.
    """
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    if matrix is not None:
        mesh.transform(matrix)
    for polygon in mesh.polygons:
        polygon.use_smooth = smooth
    if smooth and sharp_angle is not None and hasattr(mesh, "set_sharp_from_angle"):
        mesh.set_sharp_from_angle(angle=math.radians(sharp_angle))
    obj = bpy.data.objects.new(name, mesh)
    mesh.materials.append(material)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def place(location=(0, 0, 0), rotation=(0, 0, 0), scale=1.0):
    """A 4x4 matrix: scale, then XYZ Euler rotation (degrees), then translation."""
    rx, ry, rz = (math.radians(a) for a in rotation)
    rot = Matrix.Rotation(rz, 4, "Z") @ Matrix.Rotation(ry, 4, "Y") @ Matrix.Rotation(rx, 4, "X")
    size = scale if isinstance(scale, (tuple, list)) else (scale, scale, scale)
    return Matrix.Translation(Vector(location)) @ rot @ Matrix.Diagonal((*size, 1.0))


def lathe(name, profile, material, segments=64, matrix=None, closed=False, sharp_angle=50.0):
    """
    Revolves a (radius, z) profile around +Z. A point with radius 0 becomes a pole. Open ends with
    radius > 0 are capped; `closed=True` instead joins the last ring back to the first (torus-like
    rings, e.g. a glowing core band). Example: lathe("Coin", [(0,-.1),(1,-.1),(1,.1),(0,.1)], mat)
    """
    bm = bmesh.new()
    rings = []
    for radius, z in profile:
        if radius <= 1e-6:
            rings.append([bm.verts.new((0.0, 0.0, z))])
        else:
            rings.append(
                [
                    bm.verts.new(
                        (radius * math.cos(2 * math.pi * i / segments), radius * math.sin(2 * math.pi * i / segments), z)
                    )
                    for i in range(segments)
                ]
            )
    pairs = list(zip(rings, rings[1:]))
    if closed:
        pairs.append((rings[-1], rings[0]))
    for a, b in pairs:
        if len(a) == 1 and len(b) == 1:
            continue
        for i in range(segments):
            j = (i + 1) % segments
            if len(a) == 1:
                bm.faces.new((a[0], b[i], b[j]))
            elif len(b) == 1:
                bm.faces.new((a[i], a[j], b[0]))
            else:
                bm.faces.new((a[i], a[j], b[j], b[i]))
    if not closed:
        for ring in (rings[0], rings[-1]):
            if len(ring) > 2:
                bm.faces.new(ring)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _object(name, bm, material, matrix=matrix, sharp_angle=sharp_angle)


def rounded_box(name, size, material, radius=0.08, segments=3, matrix=None, taper=None, only_top=False):
    """
    A box of `size` (x, y, z) centred on the origin with bevelled (rounded) edges.
    @param taper   optional (sx, sy): scale of the BOTTOM face (a basket / tower frustum)
    @param only_top bevel only the top edges (a domed lid)
    """
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for vert in bm.verts:
        vert.co = Vector((vert.co.x * size[0], vert.co.y * size[1], vert.co.z * size[2]))
        if taper is not None and vert.co.z < 0:
            vert.co.x *= taper[0]
            vert.co.y *= taper[1]
    if radius > 0:
        edges = list(bm.edges)
        if only_top:
            edges = [e for e in edges if all(v.co.z > 0 for v in e.verts)]
        bmesh.ops.bevel(
            bm,
            geom=edges,
            offset=radius,
            offset_type="OFFSET",
            segments=segments,
            profile=0.5,
            affect="EDGES",
            clamp_overlap=True,
        )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _object(name, bm, material, matrix=matrix)


def prism(name, outline, depth, material, bevel=0.0, segments=3, matrix=None):
    """
    Extrudes a 2D outline drawn in the XZ plane (x right, z up; the front face looks at -Y) by
    `depth` toward +Y, optionally bevelling every edge (chunky rounded look).
    Example: prism("Arrow", [(-.3,0),(.3,0),(0,1)], 0.4, mat, bevel=0.08)
    """
    bm = bmesh.new()
    verts = [bm.verts.new((x, -depth / 2, z)) for x, z in outline]
    face = bm.faces.new(verts)
    result = bmesh.ops.extrude_face_region(bm, geom=[face], use_keep_orig=True)
    moved = [element for element in result["geom"] if isinstance(element, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=moved, vec=(0.0, depth, 0.0))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if bevel > 0:
        bmesh.ops.bevel(
            bm,
            geom=list(bm.edges),
            offset=bevel,
            offset_type="OFFSET",
            segments=segments,
            profile=0.5,
            affect="EDGES",
            clamp_overlap=True,
        )
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _object(name, bm, material, matrix=matrix)


def sphere(name, radius, material, matrix=None, segments=48, rings=24, scale=(1, 1, 1)):
    """A UV sphere (optionally squashed by `scale`)."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=radius)
    for vert in bm.verts:
        vert.co = Vector((vert.co.x * scale[0], vert.co.y * scale[1], vert.co.z * scale[2]))
    return _object(name, bm, material, matrix=matrix)


def sweep_arc(name, radius, start, end, section, material, steps=48, matrix=None, cap=True):
    """
    Sweeps a 2D cross-section along a circular arc in the XZ plane (centre at the origin).
    @param section [(u, v)]: u = outward radial offset, v = offset along Y (depth)
    @param start, end angles in degrees (0 = +X, 90 = +Z, counter-clockwise seen from the front)
    Used for the rebirth arrows, the basket handle and torus-like rings.
    """
    bm = bmesh.new()
    rings = []
    for step in range(steps + 1):
        angle = math.radians(start + (end - start) * step / steps)
        radial = Vector((math.cos(angle), 0.0, math.sin(angle)))
        center = radial * radius
        rings.append([bm.verts.new(center + radial * u + Vector((0.0, v, 0.0))) for u, v in section])
    count = len(section)
    for a, b in zip(rings, rings[1:]):
        for i in range(count):
            j = (i + 1) % count
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap:
        bm.faces.new(rings[0])
        bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _object(name, bm, material, matrix=matrix)


def rounded_section(width, depth, corner=0.3, steps=4):
    """A rounded-rectangle cross-section (u along width, v along depth), counter-clockwise."""
    half_w, half_d = width / 2, depth / 2
    r = min(half_w, half_d) * corner * 2
    points = []
    for cx, cy, a0 in ((half_w - r, half_d - r, 0), (-half_w + r, half_d - r, 90), (-half_w + r, -half_d + r, 180), (half_w - r, -half_d + r, 270)):
        for s in range(steps + 1):
            a = math.radians(a0 + 90 * s / steps)
            points.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return points


def circle_section(radius, steps=16):
    """A round cross-section (tube) of `radius`."""
    return [(radius * math.cos(2 * math.pi * i / steps), radius * math.sin(2 * math.pi * i / steps)) for i in range(steps)]


def text_mesh(name, body, size, depth, material, offset=0.0, bevel=0.0, matrix=None):
    """
    Extruded text (Blender's built-in font, thickened by `offset` for a chunky bold read) as a mesh
    whose front faces -Y, centred on the origin. Example: text_mesh("Day", "31", 1.0, 0.1, mat)
    """
    curve = bpy.data.curves.new(name, "FONT")
    curve.body = body
    curve.size = size
    curve.extrude = depth / 2
    curve.offset = offset
    curve.bevel_depth = bevel
    curve.bevel_resolution = 2
    curve.resolution_u = 8
    curve.align_x = "CENTER"
    curve.align_y = "CENTER"
    holder = bpy.data.objects.new(name + "Curve", curve)
    bpy.context.scene.collection.objects.link(holder)
    bpy.context.view_layer.update()
    evaluated = holder.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = bpy.data.meshes.new_from_object(evaluated)
    bpy.data.objects.remove(holder)
    bpy.data.curves.remove(curve)
    # Text lies in XY facing +Z: rotate +90 deg about X so it faces -Y with its top toward +Z.
    mesh.transform(Matrix.Rotation(math.radians(90), 4, "X"))
    if matrix is not None:
        mesh.transform(matrix)
    for polygon in mesh.polygons:
        polygon.use_smooth = False
    mesh.materials.clear()
    mesh.materials.append(material)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def transform_all(parts, matrix):
    """Bakes one transform into every part's mesh (tilts / leans a whole icon)."""
    for obj in parts:
        obj.data.transform(matrix)
    return parts


def star_outline(points, outer, inner, rotation=90.0, center=(0.0, 0.0), roundness=0):
    """A `points`-pointed star outline in the XZ plane (first tip at `rotation` degrees)."""
    out = []
    for i in range(points * 2):
        radius = outer if i % 2 == 0 else inner
        angle = math.radians(rotation + 180.0 * i / points)
        out.append((center[0] + radius * math.cos(angle), center[1] + radius * math.sin(angle)))
    return out


def rounded_rect_outline(width, height, radius, steps=6, cut_corner=None):
    """
    A rounded rectangle outline (XZ plane, centred). `cut_corner` = c cuts the top-right corner
    diagonally at distance c from the corner (the peeled sticker corner).
    """
    hw, hh = width / 2, height / 2
    points = []
    corners = ((hw - radius, hh - radius, 0), (-hw + radius, hh - radius, 90), (-hw + radius, -hh + radius, 180), (hw - radius, -hh + radius, 270))
    for cx, cz, a0 in corners:
        if cut_corner is not None and a0 == 0:
            points.append((hw, hh - cut_corner))
            points.append((hw - cut_corner, hh))
            continue
        for s in range(steps + 1):
            a = math.radians(a0 + 90 * s / steps)
            points.append((cx + radius * math.cos(a), cz + radius * math.sin(a)))
    # Corners run counter-clockwise from the top-right, so the outline is a valid simple polygon.
    return points


def trefoil_parts(prefix, center, radius, depth, material, facing="front"):
    """
    The radiation trefoil (three 60-degree blades + a centre dot) as extruded parts in the XZ plane
    at `center` (x, y, z), facing -Y. Kid-friendly: used on badges in candy colours.
    """
    cx, cy, cz = center
    parts = []
    inner, outer = radius * 0.3, radius
    for index, mid in enumerate((90.0, 210.0, 330.0)):
        outline = []
        for s in range(13):
            a = math.radians(mid - 30 + 60 * s / 12)
            outline.append((cx + outer * math.cos(a), cz + outer * math.sin(a)))
        for s in range(13):
            a = math.radians(mid + 30 - 60 * s / 12)
            outline.append((cx + inner * math.cos(a), cz + inner * math.sin(a)))
        parts.append(prism(f"{prefix}Blade{index}", outline, depth, material, matrix=place((0, cy, 0))))
    dot = [(cx + radius * 0.2 * math.cos(2 * math.pi * i / 24), cz + radius * 0.2 * math.sin(2 * math.pi * i / 24)) for i in range(24)]
    parts.append(prism(f"{prefix}Dot", dot, depth, material, matrix=place((0, cy, 0))))
    return parts


# ---------------------------------------------------------------------------------------------
# Builders. Each returns (parts, view) where view = {"yaw": deg, "pitch": deg} (optional keys).
# ---------------------------------------------------------------------------------------------


def nuke_parts(body_color=TOY_RED, nose_color=WHITE, fin_color=CHARCOAL, scale=1.0, prefix="Nuke"):
    """
    The cartoon pocket nuke (matches B4's PocketNuke): chubby candy body, white nose cone, four
    chunky swept fins, a glowing green core band and a yellow trefoil badge facing the viewer.
    Stands on its nozzle at the origin, ~3 units tall before `scale`.
    """
    s = scale
    body = toon(body_color, gloss=1.0)
    nose = toon(nose_color, gloss=1.0)
    fins = toon(fin_color, gloss=0.6)
    parts = [
        lathe(
            f"{prefix}Body",
            [(0, 0.3), (0.5, 0.3), (0.66, 0.38), (0.72, 0.56), (0.74, 1.3), (0.72, 2.16), (0, 2.16)],
            body,
            matrix=place(scale=s),
        ),
        lathe(
            f"{prefix}Nose",
            [(0, 2.12), (0.75, 2.12), (0.72, 2.34), (0.6, 2.56), (0.38, 2.74), (0.14, 2.84), (0, 2.86)],
            nose,
            matrix=place(scale=s),
        ),
        lathe(
            f"{prefix}Core",
            [(0.7, 1.02), (0.8, 1.08), (0.81, 1.25), (0.8, 1.42), (0.7, 1.48)],
            glow(GLOW_GREEN),
            matrix=place(scale=s),
            closed=True,
        ),
        lathe(f"{prefix}Nozzle", [(0, 0.0), (0.5, 0.0), (0.4, 0.16), (0.46, 0.34), (0, 0.34)], fins, matrix=place(scale=s)),
    ]
    fin_outline = [(0.45, 0.02), (1.08, -0.02), (1.12, 0.32), (0.62, 0.98), (0.45, 0.98)]
    for index, angle in enumerate((45, 135, 225, 315)):
        parts.append(
            prism(f"{prefix}Fin{index}", fin_outline, 0.14, fins, bevel=0.04, matrix=place(rotation=(0, 0, angle), scale=s))
        )
    # Yellow badge disc on the front (-Y), above the core band, with a dark trefoil.
    badge_z = 1.78
    parts.append(
        lathe(
            f"{prefix}Badge",
            [(0, -0.06), (0.3, -0.06), (0.35, 0.0), (0.3, 0.06), (0, 0.06)],
            toon(YELLOW, gloss=0.9),
            segments=48,
            matrix=place((0, -0.72 * s, badge_z * s), (90, 0, 0), s),
        )
    )
    parts += trefoil_parts(f"{prefix}Trefoil", (0, -0.79 * s, badge_z * s), 0.26 * s, 0.04 * s, toon(HAZARD_BLACK, gloss=0.3))
    return parts


def build_nuke():
    """Nuke: the red cartoon pocket nuke, leaning right (the game's product)."""
    return transform_all(nuke_parts(), place(rotation=(0, 14, 0))), {}


def build_mega_launcher():
    """MegaLauncher pass: a GOLDEN nuke with a red nose (premium '2x attack rewards')."""
    parts = nuke_parts(GOLD, nose_color=TOY_RED, fin_color=TOY_RED, prefix="Mega")
    return transform_all(parts, place(rotation=(0, 14, 0))), {}


def build_nuke_blue():
    """_NukeBlue part (Barrage composite)."""
    return transform_all(nuke_parts(SKY_BLUE, prefix="Blue"), place(rotation=(0, 14, 0))), {}


def build_nuke_green():
    """_NukeGreen part (Barrage composite)."""
    return transform_all(nuke_parts(LIME, prefix="Lime"), place(rotation=(0, 14, 0))), {}


# The egg's painted spots in object space (x, y, z, radius): three to four show from the camera.
EGG_SPOTS = (
    (-0.28, -0.62, 0.42, 0.2),
    (0.3, -0.58, -0.1, 0.26),
    (-0.18, -0.66, -0.52, 0.17),
    (0.36, -0.42, 0.66, 0.15),
    (0.66, -0.06, 0.2, 0.18),
    (-0.66, -0.18, -0.08, 0.16),
)


def egg_parts(prefix="Egg", shell=CREAM, spot=(120, 226, 70), shadow=(206, 170, 120)):
    """The pet egg: a tapered egg with painted spots (default: cream with glowing-green spots)."""
    material = toon(
        shell,
        shadow=shadow,
        light=(255, 252, 240),
        gloss=1.0,
        spots={"color": spot, "centers": EGG_SPOTS, "radius": 0.2},
    )
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=96, v_segments=48, radius=0.72)
    for vert in bm.verts:
        z = vert.co.z / 0.72
        taper = 1.0 - 0.16 * z - 0.04 * z * z
        vert.co = Vector((vert.co.x * taper, vert.co.y * taper, vert.co.z * 1.28))
    egg = _object(prefix, bm, material, matrix=place(rotation=(0, -10, 0)))
    return [egg]


def build_egg():
    """Egg: the pet egg."""
    return egg_parts(), {}


def build_cash():
    """
    Cash: a chunky stack of green bills with a yellow paper band and a '$' on top (reference: the
    HUD money stack). Tilted toward the viewer so the top bill reads.
    """
    parts = []
    bill = toon(CASH_GREEN, shadow=(40, 120, 70), light=mix_rgb(CASH_GREEN, (240, 255, 220), 0.2), gloss=0.5)
    for index in range(6):
        twist = (-3, 2, -1, 3, -2, 1)[index]
        parts.append(
            rounded_box(
                f"Bill{index}",
                (1.7, 0.86, 0.11),
                bill,
                radius=0.04,
                matrix=place((0.02 * ((index % 3) - 1), 0.0, 0.12 * index), (0, 0, twist)),
            )
        )
    top_z = 0.12 * 5 + 0.055
    parts.append(
        rounded_box("Panel", (1.42, 0.62, 0.02), toon(CASH_LIGHT, light=mix_rgb(CASH_LIGHT, (250, 255, 240), 0.15), gloss=0.3), radius=0.008, matrix=place((0.0, 0, top_z + 0.01), (0, 0, 1)))
    )
    parts.append(rounded_box("Band", (0.34, 0.96, 0.78), toon(YELLOW, gloss=0.8), radius=0.05, matrix=place((0.0, 0, 0.3))))
    dollar = text_mesh("Dollar", "$", 0.42, 0.05, toon(CASH_DARK, gloss=0.4), offset=0.02, matrix=place((0.0, 0.0, top_z + 0.09), (-90, 0, 0)))
    parts.append(dollar)
    return transform_all(parts, place(rotation=(32, 0, -8))), {"yaw": 24, "pitch": 18}


def build_lucky_wheel(spin_marks=False):
    """
    LuckyWheel: a rainbow prize wheel (8 candy slices), gold rim with light bulbs, white hub and a
    red pointer on top (reference: the colour wheel tile).
    """
    parts = []
    colors = (TOY_RED, ORANGE, YELLOW, LIME, CYAN, DEEP_BLUE, VIOLET, PINK)
    radius = 1.0
    for index, color in enumerate(colors):
        a0 = 90 + 45 * index
        outline = [(0.0, 0.0)] + [
            (radius * math.cos(math.radians(a0 + 45 * s / 8)), radius * math.sin(math.radians(a0 + 45 * s / 8)))
            for s in range(9)
        ]
        slice_mat = toon(color, light=mix_rgb(color, (255, 252, 235), 0.16), gloss=0.35)
        parts.append(prism(f"Slice{index}", outline, 0.2, slice_mat, matrix=place((0, 0, 0))))
    parts.append(sweep_arc("Rim", 1.06, 0, 360, circle_section(0.12, 20), toon(GOLD, gloss=1.0), steps=96, cap=False))
    for index in range(12):
        a = math.radians(15 + 30 * index)
        parts.append(
            sphere(f"Bulb{index}", 0.07, toon((255, 250, 220), gloss=0.9), matrix=place((1.06 * math.cos(a), -0.12, 1.06 * math.sin(a))))
        )
    parts.append(
        lathe("Hub", [(0, 0.0), (0.22, 0.0), (0.2, 0.16), (0.12, 0.24), (0, 0.27)], toon(WHITE, gloss=1.0), segments=48, matrix=place((0, 0, 0), (90, 0, 0)))
    )
    pointer = [(-0.2, 1.38), (0.2, 1.38), (0.0, 0.98)]
    parts.append(prism("Pointer", pointer, 0.26, toon(TOY_RED, gloss=0.9), bevel=0.05, matrix=place((0, -0.06, 0))))
    return transform_all(parts, place(rotation=(0, 0, 0))), {"yaw": 22, "pitch": 12}


def rebirth_arrows(prefix, radius, width, depth, colors, center_y=0.0):
    """
    Two curved arrows chasing each other around a circle (the rebirth / restart symbol): each is
    a thick rounded arc ending in a chunky arrowhead. Colours: (first arc, second arc).
    """
    parts = []
    section = rounded_section(width, depth, corner=0.35)
    for index, (start, end) in enumerate(((30.0, 168.0), (210.0, 348.0))):
        material = toon(colors[index], gloss=1.0)
        parts.append(sweep_arc(f"{prefix}Arc{index}", radius, start, end, section, material, steps=40, matrix=place((0, center_y, 0))))
        # Arrowhead at the arc end, pointing along the counter-clockwise tangent.
        a = math.radians(end)
        radial = Vector((math.cos(a), 0, math.sin(a)))
        tangent = Vector((-math.sin(a), 0, math.cos(a)))
        base = radial * radius
        half = width * 1.05
        tip = base + tangent * width * 1.35
        outline3 = [base + radial * half, tip, base - radial * half]
        outline = [(p.x, p.z) for p in outline3]
        parts.append(prism(f"{prefix}Head{index}", outline, depth, material, bevel=depth * 0.12, matrix=place((0, center_y, 0))))
    return parts


def build_rebirth():
    """Rebirth: chunky red + white circular arrows (reference: the red/white swirl button)."""
    parts = rebirth_arrows("Rebirth", 0.82, 0.36, 0.34, (TOY_RED, WHITE))
    return parts, {"yaw": 20, "pitch": 14}


def build_rebirth_token():
    """RebirthToken: a gold-rimmed purple coin with raised white rebirth arrows."""
    parts = [
        lathe(
            "Coin",
            [(0, -0.15), (0.9, -0.15), (1.0, -0.09), (1.02, 0.0), (1.0, 0.09), (0.9, 0.15), (0, 0.15)],
            toon(GOLD, gloss=1.0),
            segments=80,
            matrix=place((0, 0, 0), (90, 0, 0)),
        ),
        lathe(
            "Face",
            [(0, 0.1), (0.8, 0.1), (0.8, 0.16), (0.74, 0.2), (0, 0.2)],
            toon(PURPLE, gloss=0.6),
            segments=80,
            matrix=place((0, 0, 0), (90, 0, 0)),
        ),
    ]
    parts += rebirth_arrows("Token", 0.46, 0.17, 0.12, (WHITE, WHITE), center_y=-0.24)
    return parts, {"yaw": 24, "pitch": 12}


def acorn_parts():
    """Acorn geometry (upright, un-leaned): glossy nut, scaly darker cap (object-space checker), stem."""
    nut = lathe(
        "Nut",
        [(0, -1.0), (0.16, -0.97), (0.36, -0.86), (0.54, -0.64), (0.64, -0.36), (0.66, -0.06), (0.62, 0.12), (0, 0.12)],
        toon(NUT, shadow=(150, 70, 50), light=(250, 200, 120), gloss=1.0),
    )
    cap = lathe(
        "Cap",
        [(0, 0.62), (0.18, 0.6), (0.46, 0.5), (0.66, 0.34), (0.76, 0.16), (0.74, 0.02), (0.64, -0.04), (0, 0.02)],
        toon(BROWN, shadow=(80, 44, 50), light=(196, 140, 86), gloss=0.4, checker=(7.0, 0.35)),
    )
    stem = lathe("Stem", [(0, 0.55), (0.09, 0.55), (0.08, 0.78), (0.06, 0.9), (0, 0.92)], toon(WOOD_DARK, gloss=0.3), segments=24, matrix=place((0.04, 0, 0), (0, 14, 0)))
    return [nut, cap, stem]


def build_acorn():
    """Acorn (Harvest Feast currency), leaning a little left."""
    return transform_all(acorn_parts(), place(rotation=(0, -16, 0))), {}


def eyes(prefix, points, radius):
    """
    Cute cartoon eyes: a white ball with a glossy black pupil nudged toward the viewer (-Y) at each
    (x, y, z) in `points` (the eye-ball centre, already on the surface it sits on).
    """
    parts = []
    white = toon(WHITE, shadow=(170, 170, 210), gloss=0.6)
    pupil = toon((30, 30, 44), shadow=(10, 10, 20), light=(90, 90, 120), gloss=1.0, rim=0.1)
    for index, (x, y, z) in enumerate(points):
        parts.append(sphere(f"{prefix}Eye{index}", radius, white, matrix=place((x, y, z)), segments=32, rings=16))
        parts.append(sphere(f"{prefix}Pupil{index}", radius * 0.55, pupil, matrix=place((x, y - radius * 0.62, z + radius * 0.08)), segments=24, rings=12))
    return parts


def build_acorn_buddy():
    """_AcornBuddy part (sticker 04): the acorn with big friendly eyes."""
    parts = acorn_parts() + eyes("Buddy", [(-0.21, -0.56, -0.3), (0.21, -0.56, -0.3)], 0.15)
    return transform_all(parts, place(rotation=(0, -12, 0))), {}


def build_chest():
    """Chest: a wooden treasure chest with a domed lid, gold bands and a gold lock plate."""
    wood = toon((196, 112, 52), shadow=(110, 50, 50), gloss=0.5)
    gold = toon(GOLD, gloss=1.0)
    parts = [
        rounded_box("Base", (1.7, 1.06, 0.82), wood, radius=0.06, matrix=place((0, 0, 0.41))),
        rounded_box("Lid", (1.72, 1.08, 0.56), wood, radius=0.27, segments=5, only_top=True, matrix=place((0, 0, 1.12))),
        rounded_box("Rim", (1.78, 1.14, 0.12), gold, radius=0.04, matrix=place((0, 0, 0.84))),
    ]
    for index, x in enumerate((-0.58, 0.58)):
        parts.append(rounded_box(f"BandBase{index}", (0.18, 1.12, 0.86), gold, radius=0.04, matrix=place((x, 0, 0.41))))
        parts.append(rounded_box(f"BandLid{index}", (0.18, 1.12, 0.6), gold, radius=0.28, segments=5, only_top=True, matrix=place((x, 0, 1.13))))
    parts.append(rounded_box("Lock", (0.34, 0.12, 0.42), gold, radius=0.06, matrix=place((0, -0.55, 0.8))))
    hole = [(-0.05, 0.0), (0.05, 0.0), (0.035, 0.1), (0.07, 0.15), (0.0, 0.21), (-0.07, 0.15), (-0.035, 0.1)]
    parts.append(prism("Keyhole", hole, 0.04, toon(HAZARD_BLACK, gloss=0.2), matrix=place((0, -0.61, 0.66))))
    return parts, {}


def build_potion():
    """Potion: a round glass flask of purple potion with a glass neck and a cork (reference)."""
    liquid = toon(VIOLET, shadow=(80, 30, 140), light=(222, 170, 255), gloss=1.0)
    glass = toon(GLASS, shadow=(120, 160, 220), gloss=1.0)
    parts = [
        lathe(
            "Liquid",
            [(0, -0.8), (0.3, -0.74), (0.58, -0.54), (0.76, -0.24), (0.8, 0.04), (0.78, 0.2), (0, 0.2)],
            liquid,
        ),
        lathe(
            "Glass",
            [(0, 0.2), (0.78, 0.2), (0.72, 0.42), (0.56, 0.62), (0.36, 0.76), (0.28, 0.86), (0.28, 1.16), (0, 1.16)],
            glass,
        ),
        lathe("Lip", [(0.26, 1.1), (0.36, 1.12), (0.37, 1.2), (0.26, 1.22)], glass, closed=True),
        lathe("Cork", [(0, 1.12), (0.24, 1.12), (0.27, 1.4), (0.24, 1.48), (0, 1.48)], toon(WOOD, gloss=0.4)),
    ]
    # A little bubble sparkle inside the liquid's front.
    parts.append(sphere("Bubble", 0.1, toon((236, 210, 255), gloss=1.0), matrix=place((-0.3, -0.64, -0.2))))
    parts.append(sphere("Bubble2", 0.06, toon((236, 210, 255), gloss=1.0), matrix=place((-0.08, -0.74, -0.42))))
    return transform_all(parts, place(rotation=(0, 10, 0))), {}


def build_torch_handle():
    """_TorchHandle part: wooden torch handle with a steel band and a cup (fire composited on top)."""
    parts = [
        lathe("Handle", [(0, 0), (0.11, 0.0), (0.14, 0.6), (0.19, 1.3), (0, 1.3)], toon(WOOD, gloss=0.5)),
        lathe("Band", [(0.18, 1.0), (0.23, 1.02), (0.23, 1.16), (0.18, 1.18)], toon(STEEL, gloss=0.9), closed=True),
        lathe("Cup", [(0, 1.25), (0.2, 1.25), (0.3, 1.4), (0.38, 1.62), (0.3, 1.64), (0, 1.5)], toon(GOLD, gloss=1.0)),
    ]
    return transform_all(parts, place(rotation=(0, 22, 0))), {}


def build_upgrade():
    """Upgrade: a chunky bevelled green up arrow."""
    arrow = [(-0.3, 0.0), (0.3, 0.0), (0.3, 0.88), (0.74, 0.88), (0.0, 1.72), (-0.74, 0.88), (-0.3, 0.88)]
    parts = [prism("Arrow", arrow, 0.46, toon(GREEN, shadow=(30, 120, 70), gloss=1.0), bevel=0.1)]
    return parts, {"yaw": 26, "pitch": 14}


def build_plus_badge():
    """_PlusBadge part: a chunky bevelled green plus (composited onto icons: '+ slots')."""
    w, l = 0.28, 0.76
    plus = [(-w, -l), (w, -l), (w, -w), (l, -w), (l, w), (w, w), (w, l), (-w, l), (-w, w), (-l, w), (-l, -w), (-w, -w)]
    return [prism("Plus", plus, 0.4, toon(GREEN, shadow=(30, 120, 70), gloss=1.0), bevel=0.1)], {"yaw": 22, "pitch": 12}


def build_crate():
    """Crate (supply crate): a wooden crate with dark plank frame edges and X braces, hazard-free."""
    wood = toon(WOOD, shadow=(150, 80, 60), gloss=0.5)
    frame = toon(WOOD_DARK, shadow=(96, 50, 50), gloss=0.4)
    size = 1.5
    h = size / 2
    t = 0.2
    parts = [rounded_box("Box", (size - 0.04, size - 0.04, size - 0.04), wood, radius=0.03, matrix=place((0, 0, h)))]
    # 12 frame edges (slightly proud of the faces).
    for index, (cx, cy, cz, sx, sy, sz) in enumerate(
        [
            (0, -h, 0, size + 0.02, t, t),
            (0, h, 0, size + 0.02, t, t),
            (0, -h, size, size + 0.02, t, t),
            (0, h, size, size + 0.02, t, t),
            (-h, 0, 0, t, size + 0.02, t),
            (h, 0, 0, t, size + 0.02, t),
            (-h, 0, size, t, size + 0.02, t),
            (h, 0, size, t, size + 0.02, t),
            (-h, -h, h, t, t, size + 0.02),
            (h, -h, h, t, t, size + 0.02),
            (-h, h, h, t, t, size + 0.02),
            (h, h, h, t, t, size + 0.02),
        ]
    ):
        parts.append(rounded_box(f"Edge{index}", (sx, sy, sz), frame, radius=0.05, matrix=place((cx, cy, cz))))
    # Diagonal braces on the front (-Y) and right (+X) faces.
    diagonal = math.degrees(math.atan2(size, size))
    parts.append(rounded_box("BraceFront", (size * 1.25, 0.12, 0.16), frame, radius=0.04, matrix=place((0, -h - 0.02, h), (0, -diagonal, 0))))
    parts.append(rounded_box("BraceRight", (0.12, size * 1.25, 0.16), frame, radius=0.04, matrix=place((h + 0.02, 0, h), (diagonal, 0, 0))))
    return parts, {}


def build_aa_tower():
    """AATower: a toy anti-air tower — stud base, steel column, blue turret, twin barrels, radar."""
    parts = [
        rounded_box("Base", (1.5, 1.5, 0.36), toon(CONCRETE, gloss=0.4), radius=0.08, matrix=place((0, 0, 0.18))),
        rounded_box("Stripe", (1.56, 1.56, 0.1), toon(YELLOW, gloss=0.5), radius=0.04, matrix=place((0, 0, 0.3))),
        lathe("Column", [(0, 0.3), (0.42, 0.3), (0.32, 0.5), (0.3, 1.25), (0, 1.25)], toon(STEEL, gloss=0.8)),
        rounded_box("Turret", (1.0, 0.9, 0.6), toon(DEEP_BLUE, gloss=1.0), radius=0.2, segments=4, matrix=place((0, 0, 1.5))),
    ]
    # Twin barrels pointing up-left toward the sky (white with red tips). The lathe runs along +Z;
    # Rx(25) tips it toward the viewer, then Ry(-30) leans it left: direction ~(-0.45, -0.42, 0.78).
    for index, x in enumerate((-0.17, 0.17)):
        aim = place((x, -0.2, 1.62), (25, -30, 0))
        parts.append(lathe(f"Barrel{index}", [(0, 0), (0.1, 0), (0.1, 1.0), (0, 1.0)], toon(WHITE, gloss=0.9), segments=24, matrix=aim))
        parts.append(lathe(f"Tip{index}", [(0, 0.92), (0.13, 0.92), (0.13, 1.14), (0, 1.14)], toon(TOY_RED, gloss=0.9), segments=24, matrix=aim))
    # Radar dish on the back of the turret.
    dish = lathe("Dish", [(0, 0.0), (0.2, 0.02), (0.36, 0.1), (0.42, 0.2), (0.38, 0.2), (0.18, 0.1), (0, 0.06)], toon(WHITE, gloss=0.8), segments=40, matrix=place((0.32, 0.36, 1.9), (-30, 30, 0)))
    parts.append(dish)
    parts.append(lathe("DishPost", [(0, 1.76), (0.05, 1.76), (0.05, 1.96), (0, 1.96)], toon(STEEL, gloss=0.8), segments=16, matrix=place((0.32, 0.36, 0))))
    return parts, {}


def build_sticker():
    """Sticker (Feast Sticker): a die-cut rounded sticker with a star and a peeled top-right corner."""
    cut = 0.46
    border = rounded_rect_outline(1.7, 1.7, 0.26, cut_corner=cut)
    inner = rounded_rect_outline(1.42, 1.42, 0.16, cut_corner=cut - 0.12)
    parts = [
        prism("Paper", border, 0.08, toon(WHITE, gloss=0.6), bevel=0.02),
        prism("Ink", inner, 0.04, toon(ORANGE, shadow=(200, 70, 60), gloss=0.5), matrix=place((0, -0.05, 0))),
        prism("Star", star_outline(5, 0.56, 0.26, center=(-0.06, -0.06)), 0.14, toon(YELLOW, gloss=1.0), bevel=0.04, matrix=place((0, -0.1, 0))),
    ]
    # The peeled flap: the cut-off corner triangle folded over along the cut line (its back shows).
    hw = 0.85
    a, b = (hw, hw - cut), (hw - cut, hw)
    folded = (hw - cut, hw - cut)  # the corner reflected across the cut line
    parts.append(prism("Flap", [a, b, folded], 0.05, toon((226, 226, 238), shadow=(150, 140, 190), gloss=0.5), bevel=0.015, matrix=place((0, -0.14, 0))))
    return transform_all(parts, place(rotation=(0, -8, 0))), {"yaw": 16, "pitch": 10}


def build_shop():
    """Shop: a red shopping basket with a grid of holes and a white handle (reference: red basket)."""
    red = toon(TOY_RED, shadow=(140, 30, 70), gloss=0.9)
    hole = toon(DARK_RED, shadow=(80, 16, 40), gloss=0.0, rim=0.2)
    w, d, h = 1.8, 1.25, 1.0
    taper = 0.82
    parts = [
        rounded_box("Body", (w, d, h), red, radius=0.12, matrix=place((0, 0, h / 2)), taper=(taper, taper)),
        rounded_box("Rim", (w + 0.12, d + 0.12, 0.16), red, radius=0.07, matrix=place((0, 0, h))),
        rounded_box("Inside", (w - 0.16, d - 0.16, 0.06), hole, radius=0.04, matrix=place((0, 0, h + 0.06))),
    ]
    # Front face (-Y) is a frustum side: tilt the hole tiles to sit on it.
    tilt = math.degrees(math.atan2(d / 2 * (1 - taper), h))
    for row in range(2):
        for col in range(4):
            z = 0.3 + row * 0.36
            frac = z / h
            y = -(d / 2) * (taper + (1 - taper) * frac) - 0.01
            xs = w * (taper + (1 - taper) * frac)
            x = (col - 1.5) * xs / 4.4
            parts.append(rounded_box(f"HoleF{row}{col}", (0.26, 0.04, 0.22), hole, radius=0.03, matrix=place((x, y, z), (-tilt, 0, 0))))
    tilt_side = math.degrees(math.atan2(w / 2 * (1 - taper), h))
    for row in range(2):
        for col in range(3):
            z = 0.3 + row * 0.36
            frac = z / h
            x = (w / 2) * (taper + (1 - taper) * frac) + 0.01
            ys = d * (taper + (1 - taper) * frac)
            y = (col - 1) * ys / 3.4
            parts.append(rounded_box(f"HoleS{row}{col}", (0.04, 0.24, 0.22), hole, radius=0.03, matrix=place((x, y, z), (0, -tilt_side, 0))))
    parts.append(
        sweep_arc("Handle", 0.78, 8, 172, rounded_section(0.16, 0.2), toon(WHITE, gloss=1.0), steps=48, matrix=place((0, 0, h + 0.02)))
    )
    return parts, {"yaw": 26, "pitch": 14}


def build_daily():
    """Daily: a tear-off calendar with a red header, two binder rings and a big navy '31'."""
    parts = [
        rounded_box("Page", (1.66, 0.3, 1.5), toon(WHITE, shadow=(170, 170, 210), gloss=0.6), radius=0.14, matrix=place((0, 0, 0.75))),
        rounded_box("Header", (1.72, 0.36, 0.5), toon(TOY_RED, gloss=0.9), radius=0.14, matrix=place((0, 0, 1.36))),
    ]
    for index, x in enumerate((-0.46, 0.46)):
        parts.append(
            sweep_arc(f"Ring{index}", 0.16, -20, 200, circle_section(0.06, 12), toon(STEEL, gloss=1.0), steps=24, matrix=place((x, 0, 1.56), (0, 0, 90)))
        )
    parts.append(text_mesh("Day", "31", 0.98, 0.1, toon(NAVY, gloss=0.5), offset=0.035, matrix=place((0.0, -0.18, 0.62))))
    return parts, {"yaw": 22, "pitch": 12}


def build_facility():
    """Area10 (Mega Nuclear Facility): twin cooling towers with steam and a reactor dome."""
    concrete = toon(CONCRETE, shadow=(140, 140, 190), gloss=0.4)
    stripe = toon(TOY_RED, gloss=0.6)
    steam = toon((250, 250, 255), shadow=(190, 196, 230), gloss=0.3, rim=0.25)
    parts = [rounded_box("Ground", (2.6, 2.0, 0.16), toon(GRASS, shadow=(40, 120, 70), gloss=0.3), radius=0.08, matrix=place((0.05, 0.1, 0.08)))]
    tower = [(0, 0.16), (0.62, 0.16), (0.52, 0.6), (0.44, 1.05), (0.44, 1.3), (0.5, 1.62), (0.42, 1.62), (0.38, 1.4), (0, 1.4)]
    for index, (x, y) in enumerate(((-0.62, 0.42), (0.5, 0.62))):
        parts.append(lathe(f"Tower{index}", tower, concrete, matrix=place((x, y, 0))))
        parts.append(lathe(f"Stripe{index}", [(0.45, 1.34), (0.5, 1.36), (0.52, 1.5), (0.47, 1.52)], stripe, closed=True, matrix=place((x, y, 0))))
        for puff, (dx, dz, r) in enumerate(((0.0, 1.86, 0.32), (0.22, 2.1, 0.26), (-0.12, 2.28, 0.22))):
            parts.append(sphere(f"Steam{index}{puff}", r, steam, matrix=place((x + dx, y, dz))))
    parts.append(lathe("Dome", [(0, 1.06), (0.3, 1.0), (0.52, 0.82), (0.62, 0.56), (0.64, 0.16), (0, 0.16)], toon(WHITE, gloss=1.0), matrix=place((0.18, -0.48, 0))))
    parts.append(lathe("DomeGlow", [(0.6, 0.3), (0.7, 0.32), (0.7, 0.44), (0.6, 0.46)], glow(GLOW_GREEN), closed=True, matrix=place((0.18, -0.48, 0))))
    return parts, {}


def build_stand():
    """Area02 (Nuke Stand): a roadside wooden stand, striped awning and a nuke on the counter."""
    wood = toon(WOOD, shadow=(150, 80, 60), gloss=0.5)
    dark = toon(WOOD_DARK, shadow=(96, 50, 50), gloss=0.4)
    parts = [
        rounded_box("Counter", (2.2, 1.0, 0.9), wood, radius=0.06, matrix=place((0, 0, 0.45))),
        rounded_box("Top", (2.34, 1.12, 0.12), dark, radius=0.04, matrix=place((0, 0, 0.94))),
        rounded_box("Front", (2.0, 0.06, 0.5), toon(CREAM, gloss=0.4), radius=0.03, matrix=place((0, -0.52, 0.5))),
    ]
    for index, x in enumerate((-1.0, 1.0)):
        parts.append(rounded_box(f"Post{index}", (0.12, 0.12, 1.3), dark, radius=0.04, matrix=place((x, -0.36, 1.6))))
    # Striped awning: alternating red / white slats, tilted toward the viewer.
    for index in range(7):
        color = TOY_RED if index % 2 == 0 else WHITE
        x = -1.08 + index * 0.36
        parts.append(rounded_box(f"Slat{index}", (0.36, 1.2, 0.1), toon(color, gloss=0.8), radius=0.03, matrix=place((x, -0.2, 2.3), (-18, 0, 0))))
    parts.append(rounded_box("Scallop", (2.52, 0.12, 0.2), toon(TOY_RED, gloss=0.8), radius=0.06, matrix=place((0, -0.78, 2.12))))
    # A mini pocket nuke for sale on the counter (built at the origin, then moved onto the top).
    mini = nuke_parts(scale=0.32, prefix="StandNuke")
    transform_all(mini, place((0.45, -0.1, 1.0), (0, 10, 0)))
    return parts + mini, {"yaw": 24, "pitch": 14}


def sweep_path(name, points, radii, material, segments=24, cap=True, matrix=None):
    """
    Sweeps a circle of varying radius along a polyline in the XZ plane (horns, strings).
    @param points [(x, z)] path; @param radii one radius per point (tapers / bulges)
    The ring frame is (in-plane normal, +Y), exact for planar paths.
    """
    bm = bmesh.new()
    rings = []
    count = len(points)
    for index, ((x, z), radius) in enumerate(zip(points, radii)):
        a = points[max(index - 1, 0)]
        b = points[min(index + 1, count - 1)]
        tangent = Vector((b[0] - a[0], 0.0, b[1] - a[1])).normalized()
        normal = Vector((tangent.z, 0.0, -tangent.x))
        center = Vector((x, 0.0, z))
        ring = []
        for s in range(segments):
            angle = 2 * math.pi * s / segments
            ring.append(bm.verts.new(center + (normal * math.cos(angle) + Vector((0, 1, 0)) * math.sin(angle)) * radius))
        rings.append(ring)
    for ring_a, ring_b in zip(rings, rings[1:]):
        for i in range(segments):
            j = (i + 1) % segments
            bm.faces.new((ring_a[i], ring_a[j], ring_b[j], ring_b[i]))
    if cap:
        bm.faces.new(rings[0])
        bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _object(name, bm, material, matrix=matrix)


def build_roast_turkey():
    """_RoastTurkey part (sticker 01): a golden roast turkey with two drumsticks on a white plate."""
    roast = toon((206, 122, 52), shadow=(130, 60, 50), light=(255, 206, 120), gloss=1.0)
    bone = toon(CREAM, gloss=0.8)
    parts = [
        lathe("Plate", [(0, 0.0), (1.3, 0.0), (1.46, 0.1), (1.4, 0.15), (1.1, 0.07), (0, 0.07)], toon(WHITE, shadow=(160, 170, 210), gloss=0.9)),
        sphere("Body", 0.8, roast, matrix=place((0, 0.05, 0.56)), scale=(1.18, 0.92, 0.66)),
    ]
    for index, side in enumerate((-1, 1)):
        leg = place((side * 0.66, -0.34, 0.66), (0, side * 38, 0))
        parts.append(sphere(f"Leg{index}", 0.27, roast, matrix=leg @ place((0, 0, 0.12)), scale=(1.0, 1.0, 1.7)))
        parts.append(lathe(f"Bone{index}", [(0, 0.5), (0.07, 0.5), (0.07, 0.72), (0, 0.72)], bone, segments=20, matrix=leg))
        parts.append(sphere(f"Knob{index}a", 0.09, bone, matrix=leg @ place((-0.06, 0, 0.78))))
        parts.append(sphere(f"Knob{index}b", 0.09, bone, matrix=leg @ place((0.06, 0, 0.78))))
    for index, (x, y) in enumerate(((-1.0, -0.62), (1.02, -0.5), (0.0, -1.06), (-0.62, 0.86))):
        parts.append(sphere(f"Parsley{index}", 0.15, toon((92, 196, 70), gloss=0.4), matrix=place((x, y, 0.16)), scale=(1.2, 1.2, 0.7)))
    return parts, {"yaw": 24, "pitch": 24}


def build_gobble_bomb():
    """
    GobbleBomb (sheet-reward pet): a turkey-styled cartoon nuke — brown body, orange nose with big
    eyes, a yellow beak and red wattle, red fins and a fanned tail of autumn feathers behind.
    """
    parts = nuke_parts((156, 94, 52), nose_color=(255, 150, 50), fin_color=(222, 70, 52), prefix="Gobble")
    # Tail fan: 9 long feathers radiating from behind the body, big enough to halo the nuke.
    feather_colors = (TOY_RED, ORANGE, YELLOW, (156, 94, 52), TOY_RED, (156, 94, 52), YELLOW, ORANGE, TOY_RED)
    for index, angle in enumerate(range(-88, 89, 22)):
        color = feather_colors[index]
        a = math.radians(angle)
        center = (math.sin(a) * 1.3, 0.75, 1.45 + math.cos(a) * 1.3)
        parts.append(sphere(f"Feather{index}", 0.72, toon(color, gloss=0.6), matrix=place(center, (0, angle, 0)), scale=(0.36, 0.12, 1.0)))
    parts += eyes("Gobble", [(-0.24, -0.6, 2.42), (0.24, -0.6, 2.42)], 0.17)
    parts.append(lathe("Beak", [(0, 0), (0.12, 0), (0, 0.24)], toon(YELLOW, gloss=0.8), segments=24, matrix=place((0, -0.7, 2.2), (90, 0, 0))))
    parts.append(sphere("Wattle", 0.09, toon(TOY_RED, gloss=0.8), matrix=place((0.06, -0.78, 2.04)), scale=(0.9, 0.8, 1.6)))
    return transform_all(parts, place(rotation=(0, 8, 0))), {}


def build_harvest_egg():
    """HarvestEgg: the event egg — warm pumpkin-orange shell with brick-red autumn spots."""
    return egg_parts("HarvestEgg", shell=(255, 176, 76), spot=(206, 70, 46), shadow=(200, 96, 60)), {}


def build_hay_bales():
    """DecorHayBales: three straw bales (two below, one on top) with red twine bands."""
    straw = toon((238, 198, 92), shadow=(176, 116, 60), light=(255, 240, 170), gloss=0.3, checker=(16.0, 0.2))
    twine = toon((184, 70, 52), gloss=0.4)
    parts = []
    for index, (x, z, turn) in enumerate(((-0.7, 0.36, 0), (0.7, 0.36, 0), (0.02, 1.08, 7))):
        bale = place((x, 0, z), (0, 0, turn))
        parts.append(rounded_box(f"Bale{index}", (1.34, 0.86, 0.72), straw, radius=0.12, matrix=bale))
        for band, dx in enumerate((-0.36, 0.36)):
            parts.append(rounded_box(f"Twine{index}{band}", (0.07, 0.9, 0.76), twine, radius=0.03, matrix=bale @ place((dx, 0, 0))))
    return parts, {"yaw": 22, "pitch": 16}


def pumpkin(name, radius, location, color=ORANGE, squash=0.74):
    """A ribbed pumpkin (10 lobes, flattened, dimpled top) with a curved green stem."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=80, v_segments=40, radius=radius)
    for vert in bm.verts:
        theta = math.atan2(vert.co.y, vert.co.x)
        lobe = 1.0 + 0.075 * math.cos(10 * theta)
        height = vert.co.z / radius
        dimple = 0.18 * max(0.0, height - 0.75) / 0.25 * radius
        vert.co = Vector((vert.co.x * lobe, vert.co.y * lobe, vert.co.z * squash - dimple))
    body = _object(name, bm, toon(color, shadow=(196, 70, 54), light=(255, 214, 130), gloss=0.9), matrix=place(location))
    x, y, z = location
    stem = lathe(name + "Stem", [(0, 0), (0.11, 0), (0.08, 0.26), (0.06, 0.34), (0, 0.36)], toon((110, 132, 52), gloss=0.4), segments=20, matrix=place((x, y, z + radius * squash * 0.86), (0, 14, 0), radius / 0.8))
    return [body, stem]


def build_pumpkin_pile():
    """DecorPumpkinPile: a big orange pumpkin with two smaller ones (one pale gold) in front."""
    parts = pumpkin("Big", 0.8, (0.1, 0.35, 0.6))
    parts += pumpkin("Left", 0.55, (-0.78, -0.35, 0.42), color=(255, 196, 92))
    parts += pumpkin("Right", 0.5, (0.86, -0.42, 0.38))
    return parts, {"yaw": 20, "pitch": 18}


def build_scarecrow():
    """DecorScarecrow: wooden cross post, red plaid shirt, straw tufts, sack head, straw hat."""
    wood = toon(WOOD_DARK, shadow=(96, 50, 50), gloss=0.3)
    plaid = toon((214, 58, 52), shadow=(120, 30, 56), gloss=0.3, checker=(10.0, 0.45))
    straw = toon((246, 204, 80), shadow=(196, 120, 50), gloss=0.4)
    parts = [
        rounded_box("Post", (0.18, 0.18, 2.5), wood, radius=0.05, matrix=place((0, 0.08, 1.25))),
        rounded_box("Shirt", (0.86, 0.5, 0.86), plaid, radius=0.16, matrix=place((0, 0, 1.4))),
        rounded_box("Sleeves", (2.0, 0.34, 0.34), plaid, radius=0.14, matrix=place((0, 0, 1.66))),
        rounded_box("Belt", (0.9, 0.54, 0.12), toon(BROWN, gloss=0.3), radius=0.04, matrix=place((0, 0, 1.0))),
    ]
    for index, side in enumerate((-1, 1)):
        parts.append(lathe(f"Tuft{index}", [(0, 0), (0.2, 0), (0, 0.32)], straw, segments=12, matrix=place((side * 1.0, 0, 1.66), (0, side * 90, 0))))
    parts.append(lathe("TuftLow", [(0, 0), (0.2, 0), (0, 0.3)], straw, segments=12, matrix=place((0, 0, 0.96), (180, 0, 0))))
    parts.append(sphere("Head", 0.38, toon((232, 200, 140), shadow=(170, 120, 90), gloss=0.3), matrix=place((0, 0, 2.18)), scale=(1.0, 0.95, 1.05)))
    for index, x in enumerate((-0.14, 0.14)):
        parts.append(sphere(f"Button{index}", 0.07, toon((40, 36, 50), gloss=1.0, rim=0.1), matrix=place((x, -0.34, 2.24))))
    parts.append(sweep_path("Smile", [(-0.16, 2.06), (-0.08, 2.0), (0.0, 1.98), (0.08, 2.0), (0.16, 2.06)], [0.025] * 5, toon((40, 36, 50), gloss=0.2), segments=8, matrix=place((0, -0.36, 0))))
    parts.append(lathe("Brim", [(0, 2.44), (0.66, 2.42), (0.7, 2.46), (0.62, 2.5), (0, 2.5)], straw, segments=48, matrix=place((0, 0, 0)) @ place(rotation=(0, -8, 0))))
    parts.append(lathe("Crown", [(0, 2.46), (0.36, 2.46), (0.3, 2.7), (0.14, 2.86), (0, 2.88)], straw, segments=40, matrix=place(rotation=(0, -8, 0))))
    return parts, {"yaw": 18, "pitch": 10}


def build_cornucopia():
    """DecorCornucopia: a wicker horn of plenty curling up at its tip, fruit spilling from the mouth."""
    wicker = toon(WOOD, shadow=(150, 80, 60), light=(250, 210, 140), gloss=0.4, checker=(11.0, 0.3))
    path, radii = [], []
    for step in range(41):
        t = step / 40
        angle = math.radians(200 * t)
        x = 0.55 - 1.7 * t + 0.25 * math.sin(angle) * t
        z = 0.62 + 0.95 * t ** 2.6
        path.append((x, z))
        radii.append(0.6 * (1 - t) ** 1.05 + 0.035)
    parts = [sweep_path("Horn", path, radii, wicker, segments=40)]
    parts.append(lathe("Mouth", [(0, 0), (0.56, 0), (0.56, 0.04), (0, 0.04)], toon((110, 56, 40), gloss=0.0, rim=0.2), segments=40, matrix=place((0.58, 0, 0.62), (0, 90, 0))))
    fruit = (
        ("Orange", (0.86, -0.2, 0.42), 0.3, ORANGE),
        ("Apple", (0.6, -0.5, 0.3), 0.27, TOY_RED),
        ("Pear", (1.08, 0.14, 0.62), 0.24, (190, 220, 70)),
    )
    for name, center, radius, color in fruit:
        parts.append(sphere(name, radius, toon(color, gloss=1.0), matrix=place(center)))
    for index, (dx, dz) in enumerate(((0, 0), (0.16, 0.02), (-0.16, 0.02), (0.08, -0.14), (-0.08, -0.14), (0, -0.27), (0.0, 0.15))):
        parts.append(sphere(f"Grape{index}", 0.1, toon(VIOLET, gloss=1.0), matrix=place((0.72 + dx, -0.32, 0.86 + dz))))
    return parts, {"yaw": 14, "pitch": 14}


def build_garland():
    """DecorGarland: a sagging twine of autumn bunting flags (orange / red / yellow / brown)."""
    # Compact enough to read at HUD size: 5 big flags on a deep sag (span 2.4, sag 0.6).
    half, sag = 1.2, 0.6

    def height(x):
        """Twine height at x (parabolic sag)."""
        return 1.0 - sag * (1 - (x / half) ** 2)

    points = [(-half + 2 * half * i / 30, height(-half + 2 * half * i / 30)) for i in range(31)]
    parts = [sweep_path("Twine", points, [0.05] * len(points), toon((150, 92, 56), gloss=0.3), segments=12)]
    colors = (ORANGE, TOY_RED, YELLOW, (156, 94, 52), ORANGE)
    for index in range(5):
        x = -0.84 + index * 0.42
        slope = math.degrees(math.atan(sag * 2 * x / (half**2)))
        flag = [(-0.21, 0.0), (0.21, 0.0), (0.0, -0.62)]
        parts.append(prism(f"Flag{index}", flag, 0.08, toon(colors[index], gloss=0.6), bevel=0.025, matrix=place((x, 0.0, height(x) - 0.02), (0, -slope, 0))))
    for index, x in enumerate((-half, half)):
        parts.append(sphere(f"Knot{index}", 0.1, toon((150, 92, 56), gloss=0.3), matrix=place((x, 0, 1.0))))
    return parts, {"yaw": 12, "pitch": 8}


def build_pedestal():
    """_Pedestal part (DecorTurkeyStatue): a stone plinth with a gold trim band and plaque."""
    stone = toon(CONCRETE, shadow=(140, 140, 190), gloss=0.5)
    gold = toon(GOLD, gloss=1.0)
    parts = [
        rounded_box("Foot", (1.7, 1.2, 0.3), stone, radius=0.08, matrix=place((0, 0, 0.15))),
        rounded_box("Block", (1.34, 0.94, 0.7), stone, radius=0.06, matrix=place((0, 0, 0.64))),
        rounded_box("Trim", (1.4, 1.0, 0.1), gold, radius=0.03, matrix=place((0, 0, 0.94))),
        rounded_box("Cap", (1.6, 1.14, 0.2), stone, radius=0.07, matrix=place((0, 0, 1.08))),
        rounded_box("Plaque", (0.66, 0.06, 0.3), gold, radius=0.04, matrix=place((0, -0.48, 0.62))),
    ]
    return parts, {"yaw": 22, "pitch": 14}


def build_close():
    """Close: a chunky bevelled white X (sits on the red stud close button; reads standalone too)."""
    w, l = 0.24, 0.86
    plus = [(-w, -l), (w, -l), (w, -w), (l, -w), (l, w), (w, w), (w, l), (-w, l), (-w, w), (-l, w), (-l, -w), (-w, -w)]
    cross = [(x * math.cos(math.pi / 4) - z * math.sin(math.pi / 4), x * math.sin(math.pi / 4) + z * math.cos(math.pi / 4)) for x, z in plus]
    material = toon(WHITE, shadow=(160, 150, 210), gloss=0.9)
    return [prism("Cross", cross, 0.4, material, bevel=0.1)], {"yaw": 20, "pitch": 12}


def build_arrow():
    """Arrow: the tutorial / objective pointer — a chunky yellow 3D arrow pointing DOWN."""
    arrow = [(-0.3, 1.72), (-0.3, 0.84), (-0.74, 0.84), (0.0, 0.0), (0.74, 0.84), (0.3, 0.84), (0.3, 1.72)]
    material = toon(YELLOW, shadow=(222, 110, 40), light=(255, 236, 120), gloss=0.8)
    return [prism("Pointer", arrow, 0.46, material, bevel=0.1)], {"yaw": 24, "pitch": 12}


def build_robux():
    """
    Robux: an ORIGINAL green hexagon coin (premium-currency look for price tags): bevelled
    hexagonal body, raised darker hexagon plate and a light centre hexagon. Not Roblox's logo file.
    """
    body = toon((64, 200, 96), shadow=(30, 110, 80), gloss=1.0)
    plate = toon((34, 150, 74), shadow=(20, 90, 60), gloss=0.6)
    center = toon((170, 244, 170), shadow=(80, 180, 110), gloss=0.9)
    turn = place((0, 0, 0), (90, 0, 0))
    parts = [
        lathe("Hex", [(0, -0.16), (0.86, -0.16), (1.0, -0.07), (1.0, 0.07), (0.86, 0.16), (0, 0.16)], body, segments=6, matrix=turn),
        lathe("Plate", [(0, 0.15), (0.68, 0.15), (0.72, 0.19), (0.68, 0.23), (0, 0.23)], plate, segments=6, matrix=turn),
        lathe("Center", [(0, 0.22), (0.34, 0.22), (0.38, 0.26), (0.34, 0.31), (0, 0.31)], center, segments=6, matrix=turn),
    ]
    return parts, {"yaw": 24, "pitch": 12}


# ---------------------------------------------------------------------------------------------
# Dino Valley (World 2, owner R57; spec docs/superpowers/specs/2026-10-31-world2-design.md §2/§16)
#
# Palette (spec §2): fern green / sand / mossy stone / amber orange / bone cream / lava candy-orange.
# Kid rules: cartoon fossil dog-bones (never skulls), a fern (never an insect) in the amber, round
# smiling dinos with no teeth or claws, candy "warm jelly" lava. Who uses the icons: docs/icons.md
# "Dino Valley icons (W9, R57)".
# ---------------------------------------------------------------------------------------------

# Bone cream with a warm amber-tan shadow (a fossil, never a grey / dirty bone) and a warm light.
BONE_CREAM = (252, 240, 212)
BONE_SHADOW = (206, 150, 98)
BONE_LIGHT = (255, 252, 238)
# Glowing amber: bright orange base, red-orange shadow, honey-yellow light.
AMBER = (255, 160, 34)
AMBER_DARK = (214, 84, 30)
AMBER_LIGHT = (255, 226, 120)
# A fern seen THROUGH amber: green pulled toward the amber's orange so it reads "inside".
FERN_IN_AMBER = (104, 150, 26)
DINO_GREEN = (104, 206, 84)
DINO_BELLY = (214, 242, 150)
LAVA = (255, 120, 44)
VOLCANO_STONE = (160, 110, 82)
SWIRL_PURPLE = (150, 84, 232)


def no_hull(obj):
    """Flags a part so add_hulls() draws no inner line around it (it looks sunk into a surface)."""
    obj["no_hull"] = True
    return obj


def sparkle(name, size, location, color=AMBER, depth=0.08):
    """
    A chunky 4-point glint star facing the viewer (the 'amber glint' on Bones / bone heaps).
    Example: sparkle("Glint", 0.3, (0.8, -0.5, 0.6))
    """
    outline = star_outline(4, size, size * 0.3, rotation=90.0)
    material = toon(color, shadow=AMBER_DARK, light=AMBER_LIGHT, gloss=0.7, rim=0.2)
    return prism(name, outline, depth, material, bevel=depth * 0.3, matrix=place(location))


def bone_parts(prefix, matrix=None, length=2.0, radius=0.25, knob=0.36, cream=BONE_CREAM):
    """
    One chunky cartoon fossil dog-bone, centred on the origin and lying along X: a slightly waisted
    round shaft and TWO round knobs at each end, side by side in the XZ plane (the classic dog-bone
    silhouette faces the viewer). Cream with a warm amber-tan shadow. `matrix` places the bone;
    `cream` lets heaps shade their back rows a touch darker so the rows separate when small.
    Example: bone_parts("Bone", place((0, 0, 0), (0, -30, 0)))
    """
    material = toon(cream, shadow=BONE_SHADOW, light=BONE_LIGHT, gloss=0.9, rim=0.35)
    half = length / 2
    base = matrix if matrix is not None else Matrix.Identity(4)
    # The lathe runs along +Z: rotate it +90 deg about Y so the shaft lies along X.
    shaft = lathe(
        f"{prefix}Shaft",
        [(0, -half), (radius * 1.08, -half), (radius * 0.94, -half * 0.55), (radius * 0.86, 0.0), (radius * 0.94, half * 0.55), (radius * 1.08, half), (0, half)],
        material,
        segments=40,
        matrix=base @ place(rotation=(0, 90, 0)),
    )
    parts = [shaft]
    for end, x in enumerate((-half, half)):
        for side, z in enumerate((-knob * 0.74, knob * 0.74)):
            parts.append(sphere(f"{prefix}Knob{end}{side}", knob, material, matrix=base @ place((x * 1.02, 0.0, z)), segments=40, rings=20))
    return parts


def build_bones():
    """
    Bones (Dino Valley currency): one chunky cream fossil dog-bone on a diagonal with an amber
    glint star by its upper knob. No skulls (spec §2 kid rules).
    """
    parts = bone_parts("Bone", place(rotation=(0, -34, 0)))
    parts.append(sparkle("Glint", 0.36, (0.92, -0.52, 1.02)))
    return parts, {"yaw": 22, "pitch": 14}


def amber_parts(prefix="Amber", matrix=None):
    """
    The Amber gem: a faceted teardrop nugget of glowing amber (point up), slightly flattened front
    to back, with a tiny green fern-leaf fossil "inside" it (no hull line, amber-tinted green) and
    a white glint. Kid rule: a fern, never an insect.
    """
    base = matrix if matrix is not None else Matrix.Identity(4)
    gem = toon(AMBER, shadow=AMBER_DARK, light=AMBER_LIGHT, gloss=1.0, rim=0.3)
    profile = [(0, -1.0), (0.34, -0.94), (0.62, -0.74), (0.78, -0.44), (0.8, -0.12), (0.7, 0.24), (0.5, 0.6), (0.24, 0.92), (0, 1.12)]
    squash = 0.72
    # 14 facets around + flat shading below 20 deg: a cut-gem read, not a smooth blob.
    body = lathe(f"{prefix}Gem", profile, gem, segments=14, sharp_angle=20, matrix=base @ place(scale=(1.0, squash, 1.0)))
    parts = [body]
    # The fern, laid on a plane just in front of the gem's front face (ortho camera: it reads as
    # seen through the surface). A curved midrib and paired leaflets shrinking toward the tip.
    fern = toon(FERN_IN_AMBER, shadow=(70, 104, 22), light=(170, 196, 60), gloss=0.0, rim=0.1)
    front = -0.8 * squash - 0.02
    rib = [(0.06 - 0.1 * (t / 8) ** 2, -0.56 + 1.0 * t / 8) for t in range(9)]
    parts.append(no_hull(sweep_path(f"{prefix}Rib", rib, [0.035] * len(rib), fern, segments=10, matrix=base @ place((0, front, 0)))))
    for index in range(5):
        t = (index + 1) / 6
        x, z = rib[round(t * 8)]
        size = 0.2 * (1.1 - t)
        for side in (-1, 1):
            leaf = place((x + side * size * 0.95, front, z + size * 0.25), (0, side * -30, 0))
            parts.append(no_hull(sphere(f"{prefix}Leaf{index}{side}", size, fern, matrix=base @ leaf, segments=20, rings=10, scale=(1.0, 0.25, 0.42))))
    parts.append(no_hull(sphere(f"{prefix}LeafTip", 0.07, fern, matrix=base @ place((rib[-1][0], front, rib[-1][1] + 0.04)), segments=16, rings=8, scale=(0.8, 0.25, 1.3))))
    # Glass glint: a small white blob upper-left (the 'glowing gem' sparkle).
    glint = sphere(f"{prefix}Glint", 0.08, toon((255, 250, 232), gloss=0.0, rim=0.0), matrix=base @ place((-0.38, front + 0.1, 0.44), (0, -24, 0)), segments=16, rings=8, scale=(1.0, 0.4, 1.5))
    parts.append(no_hull(glint))
    return parts


def build_amber():
    """Amber (Dino rebirth token): the glowing amber teardrop with a fern fossil, tilted a little."""
    return amber_parts(matrix=place(rotation=(0, 10, 0))), {"yaw": 20, "pitch": 12}


def island_parts(prefix="Island"):
    """
    A little floating island: a domed grass top with a rounded lip over a faceted, tapering rock /
    dirt underside (a Roblox-sim world bubble). Top surface sits at z ~ 0.3, radius ~1.4.
    """
    grass = toon(GRASS, shadow=(40, 128, 72), light=(186, 240, 120), gloss=0.5)
    dirt = toon((176, 112, 70), shadow=(110, 60, 60), light=(226, 170, 110), gloss=0.3)
    return [
        lathe(f"{prefix}Grass", [(0, 0.0), (1.38, 0.0), (1.48, 0.08), (1.46, 0.2), (1.3, 0.28), (0.8, 0.32), (0, 0.34)], grass, segments=64),
        lathe(
            f"{prefix}Rock",
            [(0, -1.2), (0.22, -1.14), (0.62, -0.78), (1.02, -0.4), (1.34, -0.08), (1.4, 0.02), (0, 0.02)],
            dirt,
            segments=9,
            sharp_angle=24,
        ),
    ]


def build_world_nuke_town():
    """
    WorldNukeTown (world tab: the main world): the little green island with the red cartoon pocket
    nuke (B4 PocketNuke parts) standing in the middle, a tiny red-roof house and a round tree.
    """
    parts = island_parts("Town")
    # Tiny house back-left: cream walls, red pitched roof, blue door.
    house = place((-0.72, 0.42, 0.3), (0, 0, -18))
    parts.append(rounded_box("HouseWalls", (0.62, 0.56, 0.48), toon(CREAM, shadow=(200, 160, 150), gloss=0.5), radius=0.05, matrix=house @ place((0, 0, 0.24))))
    roof = [(-0.42, 0.0), (0.42, 0.0), (0.0, 0.38)]
    parts.append(prism("HouseRoof", roof, 0.66, toon(TOY_RED, gloss=0.9), bevel=0.04, matrix=house @ place((0, 0, 0.48)) @ place(rotation=(0, 0, 0))))
    parts.append(rounded_box("HouseDoor", (0.16, 0.04, 0.24), toon(DEEP_BLUE, gloss=0.6), radius=0.03, matrix=house @ place((0.08, -0.29, 0.12))))
    # A round tree back-right.
    parts.append(lathe("TreeTrunk", [(0, 0.28), (0.07, 0.28), (0.06, 0.62), (0, 0.62)], toon(WOOD_DARK, gloss=0.3), segments=16, matrix=place((0.86, 0.5, 0))))
    parts.append(sphere("TreeTop", 0.34, toon((70, 176, 70), shadow=(30, 110, 70), gloss=0.6), matrix=place((0.86, 0.5, 0.86)), segments=32, rings=16))
    # The pocket nuke, centre-front, leaning right like the Nuke icon.
    nuke = nuke_parts(scale=0.6, prefix="TownNuke")
    transform_all(nuke, place((0.08, -0.2, 0.28), (0, 12, 0)))
    return parts + nuke, {"yaw": 24, "pitch": 18}


def build_world_dino():
    """
    WorldDino (world tab: Dino Valley): a cute round friendly green dino head — big eyes, a soft
    smile, pink cheeks, a pale muzzle with nostril dots and a row of round yellow spikes along its
    crown — turned a little to the left (3/4 view: snout + spikes read "dino", not "frog"), with a
    small brown volcano topped by candy-orange jelly lava peeking out behind. No teeth, no claws.
    """
    skin = toon(DINO_GREEN, shadow=(36, 120, 90), light=(190, 246, 140), gloss=0.8)
    muzzle = toon(DINO_BELLY, shadow=(120, 170, 110), light=(250, 255, 220), gloss=0.8)
    head = [
        sphere("Head", 1.0, skin, matrix=place((0, 0, 0)), scale=(1.0, 0.95, 0.9)),
        sphere("Muzzle", 0.72, muzzle, matrix=place((0, -0.66, -0.32)), scale=(1.12, 0.94, 0.72)),
    ]
    # Soft round spikes along the crown / back of the head (candy yellow, blunt tips: friendly).
    # Rx(-tilt) turns each lathe's +Z axis onto the head normal direction (0, y, z).
    plate = toon(YELLOW, shadow=(226, 120, 40), light=(255, 246, 170), gloss=0.8)
    for index, (y, z, r) in enumerate(((-0.12, 0.8, 0.27), (0.38, 0.74, 0.27), (0.78, 0.4, 0.24), (0.94, -0.08, 0.2))):
        tilt = math.degrees(math.atan2(y, z))
        spike = [(0, -0.12), (r, -0.12), (r * 0.92, r * 0.4), (r * 0.6, r * 1.0), (r * 0.26, r * 1.36), (0, r * 1.44)]
        head.append(lathe(f"Spike{index}", spike, plate, segments=32, matrix=place((0, y, z), (-tilt, 0, 0))))
    # Nostril dots on the muzzle top-front.
    nostril = toon((40, 90, 60), shadow=(20, 50, 40), gloss=0.4, rim=0.1)
    for index, x in enumerate((-0.2, 0.2)):
        head.append(sphere(f"Nostril{index}", 0.065, nostril, matrix=place((x, -1.22, -0.1)), segments=16, rings=8, scale=(1.2, 0.6, 0.9)))
    # The smile: a soft upward curve across the muzzle front (no teeth).
    smile = [(-0.34 + 0.085 * i, -0.36 - 0.14 * (1 - ((-0.34 + 0.085 * i) / 0.34) ** 2)) for i in range(9)]
    head.append(sweep_path("Smile", smile, [0.05] * len(smile), toon((50, 70, 50), gloss=0.2, rim=0.1), segments=10, matrix=place((0, -1.26, 0))))
    # Pink cheek blush (no hull: painted-on).
    blush = toon((255, 150, 170), shadow=(230, 110, 140), gloss=0.0, rim=0.0)
    for index, x in enumerate((-0.64, 0.64)):
        head.append(no_hull(sphere(f"Blush{index}", 0.16, blush, matrix=place((x, -0.72, -0.06), (0, 0, 40 if x > 0 else -40)), segments=20, rings=10, scale=(1.0, 0.3, 0.7))))
    # Turn the head 14 deg to its left: with the front-right camera that is a ~32 deg 3/4 view.
    turn = place(rotation=(0, 0, -14))
    parts = transform_all(head, turn)
    # Big friendly eyes, placed AFTER the turn so both pupils look straight at the camera
    # (eyes() aims pupils down -Y, which would look past the viewer on a turned head).
    yaw, pitch = math.radians(18), math.radians(12)
    toward = Vector((math.sin(yaw) * math.cos(pitch), -math.cos(yaw) * math.cos(pitch), math.sin(pitch)))
    white = toon(WHITE, shadow=(170, 170, 210), gloss=0.6)
    pupil = toon((30, 30, 44), shadow=(10, 10, 20), light=(90, 90, 120), gloss=1.0, rim=0.1)
    radius = 0.26
    for index, local in enumerate(((-0.36, -0.74, 0.32), (0.36, -0.74, 0.32))):
        center = turn @ Vector(local)
        parts.append(sphere(f"DinoEye{index}", radius, white, matrix=place(tuple(center)), segments=32, rings=16))
        look = center + toward * radius * 0.62 + Vector((0, 0, radius * 0.06))
        parts.append(sphere(f"DinoPupil{index}", radius * 0.56, pupil, matrix=place(tuple(look)), segments=24, rings=12))
    # Volcano behind, peeking over the left of the head: brown cone, candy-orange jelly lava top.
    volcano = place((-1.42, 1.5, -0.32), scale=0.74)
    stone = toon(VOLCANO_STONE, shadow=(110, 70, 80), light=(214, 168, 120), gloss=0.3)
    lava = toon(LAVA, shadow=(220, 70, 60), light=(255, 214, 110), gloss=1.0)
    parts.append(lathe("Volcano", [(0, 0.0), (1.0, 0.0), (0.86, 0.4), (0.56, 1.0), (0.42, 1.24), (0, 1.2)], stone, segments=10, sharp_angle=26, matrix=volcano))
    parts.append(lathe("Lava", [(0, 1.2), (0.36, 1.22), (0.47, 1.24), (0.46, 1.32), (0.3, 1.38), (0, 1.38)], lava, segments=32, matrix=volcano))
    for index, (angle, drop) in enumerate(((-110, 0.36), (-60, 0.22), (-150, 0.18))):
        a = math.radians(angle)
        r = 0.5 + drop * 0.25
        parts.append(sphere(f"Drip{index}", 0.1, lava, matrix=volcano @ place((r * math.cos(a), r * math.sin(a), 1.22 - drop * 0.6)), segments=20, rings=10, scale=(1.0, 1.0, 1.0 + drop * 4)))
    return parts, {"yaw": 18, "pitch": 12}


def swirl_parts(prefix, radius, matrix, arms=3, colors=(CYAN, (196, 246, 255), CYAN), base=SWIRL_PURPLE):
    """
    A time-portal swirl facing the viewer (-Y): a purple disc with `arms` glowing cyan spiral arms
    that thin toward a bright centre (TimeMachine portal, the TimeTravelerPack watch face).
    `matrix` places the disc centre; the disc front is at local y = -0.05 * radius.
    """
    parts = [
        lathe(
            f"{prefix}Disc",
            [(0, -0.05 * radius), (radius, -0.05 * radius), (radius, 0.05 * radius), (0, 0.05 * radius)],
            toon(base, shadow=(84, 40, 150), light=(204, 160, 255), gloss=0.4, rim=0.2),
            segments=64,
            matrix=matrix @ place(rotation=(90, 0, 0)),
        )
    ]
    for arm in range(arms):
        points, radii = [], []
        for step in range(25):
            t = step / 24
            angle = math.radians(120 * arm + 300 * t)
            r = radius * (0.1 + 0.8 * t)
            points.append((r * math.cos(angle), r * math.sin(angle)))
            radii.append(radius * (0.035 + 0.06 * t))
        parts.append(sweep_path(f"{prefix}Arm{arm}", points, radii, glow(colors[arm % len(colors)], light=(240, 255, 255)), segments=12, matrix=matrix @ place((0, -0.06 * radius, 0))))
    parts.append(sphere(f"{prefix}Core", radius * 0.14, glow((220, 250, 255), light=(255, 255, 255)), matrix=matrix @ place((0, -0.06 * radius, 0)), segments=24, rings=12, scale=(1.0, 0.5, 1.0)))
    return parts


def build_time_machine():
    """
    TimeMachine (WORLD UNLOCKED popup, portal prompts): the stud-toy Time Machine of the lobby —
    a gold clock-face ring with 12 white hour studs around a purple/cyan swirl portal, standing
    on a chunky blue base with two round dials (red + yellow) and a lever with a red knob.
    """
    gold = toon(GOLD, shadow=(206, 110, 40), light=(255, 240, 170), gloss=1.0)
    center = place((0, 0, 1.36))
    parts = [sweep_arc("Ring", 1.0, 0, 360, rounded_section(0.34, 0.42, corner=0.4), gold, steps=96, cap=False, matrix=center)]
    stud = toon(WHITE, shadow=(170, 170, 210), gloss=0.9)
    for hour in range(12):
        a = math.radians(90 - 30 * hour)
        size = 0.09 if hour % 3 else 0.12
        parts.append(
            lathe(f"Hour{hour}", [(0, 0), (size, 0), (size, 0.08), (0, 0.08)], stud, segments=20, matrix=center @ place((math.cos(a), -0.2, math.sin(a)), (90, 0, 0)))
        )
    parts += swirl_parts("Portal", 0.86, center)
    base = toon(DEEP_BLUE, shadow=(40, 50, 130), light=(150, 190, 250), gloss=0.7)
    parts.append(rounded_box("Base", (2.5, 1.1, 0.42), base, radius=0.1, matrix=place((0, 0, 0.21))))
    parts.append(rounded_box("Plinth", (0.9, 0.62, 0.3), base, radius=0.08, matrix=place((0, 0, 0.5))))
    # Chunky round dials on the base front (each with a white pointer tick).
    for index, (x, color) in enumerate(((-0.84, TOY_RED), (0.84, YELLOW))):
        dial = place((x, -0.56, 0.22), (90, 0, 0))
        parts.append(lathe(f"Dial{index}", [(0, 0), (0.16, 0), (0.15, 0.08), (0.1, 0.11), (0, 0.11)], toon(color, gloss=1.0), segments=32, matrix=dial))
        parts.append(rounded_box(f"Tick{index}", (0.04, 0.03, 0.12), stud, radius=0.012, matrix=place((x + 0.02, -0.68, 0.26), (0, -30, 0))))
    # The lever on the right: steel stick leaning out, red ball knob.
    lever = place((1.04, 0.0, 0.42), (0, 28, 0))
    parts.append(lathe("LeverStick", [(0, 0), (0.06, 0), (0.06, 0.78), (0, 0.78)], toon(STEEL, gloss=0.9), segments=16, matrix=lever))
    parts.append(sphere("LeverKnob", 0.16, toon(TOY_RED, gloss=1.0), matrix=lever @ place((0, 0, 0.84)), segments=32, rings=16))
    return parts, {"yaw": 22, "pitch": 14}


# Bone-heap layouts: (x, z, in-plane tilt deg, depth y) per bone, drawn back to front; rows
# shrink upward (a pyramid silhouette) and upper rows sit a little in front.
#   medium = a 3-2-1 heap of six;  large = a 4-3-2-1 heap of ten (+ amber nuggets and glints).
BONE_HEAPS = {
    "medium": (
        (-1.3, 0.0, 14, 0.5), (0.0, 0.0, -12, 0.5), (1.3, 0.0, 12, 0.5),
        (-0.65, 0.8, -12, 0.1), (0.65, 0.8, 12, 0.1),
        (0.0, 1.6, -6, -0.3),
    ),
    "large": (
        (-1.86, 0.0, 12, 0.7), (-0.62, 0.0, -14, 0.7), (0.62, 0.0, 14, 0.7), (1.86, 0.0, -12, 0.7),
        (-1.24, 0.78, -14, 0.3), (0.0, 0.78, 10, 0.3), (1.24, 0.78, -12, 0.3),
        (-0.62, 1.56, 12, -0.1), (0.62, 1.56, -14, -0.1),
        (0.0, 2.34, -6, -0.5),
    ),
}
# The alternate tone of neighbouring bones (a warmer fossil tan) so overlapping bones separate at
# 40 px, where the 5 px inner lines vanish.
BONE_TAN = (236, 202, 150)


def bone_tone(index, depth):
    """Cream / tan alternation per bone, darkened slightly with depth (0 front .. 1 back)."""
    base = BONE_TAN if index % 2 else BONE_CREAM
    return tuple(round(c) for c in mix_rgb(base, BONE_SHADOW, 0.2 * depth))


def bone_heap(size):
    """A stacked heap of fossil bones (BONE_HEAPS[size]) in alternating cream / tan tones."""
    layout = BONE_HEAPS[size]
    back, front = max(y for *_, y in layout), min(y for *_, y in layout)
    parts = []
    for index, (x, z, tilt, y) in enumerate(layout):
        cream = bone_tone(index, (y - front) / (back - front))
        parts += bone_parts(f"Heap{index}", place((x, y, z), (0, tilt, 0)), length=1.42, radius=0.23, knob=0.31, cream=cream)
    return parts


def build_bones_pack_small():
    """
    BonesPackSmall ('Pile of Bones' product): three fossil bones lying in a neat diagonal stack
    (the Bones currency bone, times three), front bone lowest.
    """
    parts = []
    tilt = -28
    along = Vector((math.cos(math.radians(-tilt)), 0.0, math.sin(math.radians(-tilt))))
    across = Vector((-along.z, 0.0, along.x))
    for index, step in enumerate((1, 0, -1)):
        # Staggered along the bone axis (not a ladder): each upper bone slides right.
        center = across * 0.66 * step + along * 0.36 * step + Vector((0.0, 0.3 * step, 0.0))
        parts += bone_parts(f"Stack{index}", place(tuple(center), (0, tilt, 0)), length=1.9, radius=0.24, knob=0.33, cream=bone_tone(index, (step + 1) / 2))
    return parts, {"yaw": 20, "pitch": 14}


def build_bones_pack():
    """BonesPack ('Sack of Bones' product, medium): a 3-2-1 heap of six bones with one glint."""
    parts = bone_heap("medium") + [sparkle("Glint", 0.4, (1.0, -0.9, 2.04))]
    return parts, {"yaw": 20, "pitch": 16}


def build_bones_pack_large():
    """
    BonesPackLarge ('Crate of Bones' product): a big 4-3-2-1 heap of ten bones with amber nuggets
    tucked into the front and two amber glints (the 'jackpot' read).
    """
    parts = bone_heap("large")
    for index, (x, z, s, turn) in enumerate(((-1.24, 0.14, 0.44, -14), (1.24, 0.14, 0.44, 16), (0.0, 0.92, 0.42, 6))):
        parts += amber_parts(f"Nugget{index}", matrix=place((x, -0.8, z), (0, turn, 0), s))
    parts.append(sparkle("Glint0", 0.46, (1.2, -1.0, 2.74)))
    parts.append(sparkle("Glint1", 0.34, (-1.62, -1.0, 2.0)))
    return parts, {"yaw": 20, "pitch": 16}


def build_pocket_watch():
    """
    _PocketWatch part (TimeTravelerPack): a golden pocket-watch with a time-swirl face, two little
    gold hands, a crown and a bow ring on top. Faces the viewer, tilted a little.
    """
    gold = toon(GOLD, shadow=(206, 110, 40), light=(255, 240, 170), gloss=1.0)
    turn = place(rotation=(90, 0, 0))
    parts = [
        lathe("Case", [(0, -0.18), (0.92, -0.18), (1.02, -0.1), (1.04, 0.0), (1.02, 0.1), (0.92, 0.18), (0, 0.18)], gold, segments=72, matrix=turn),
        lathe("Bezel", [(0.84, 0.16), (0.94, 0.17), (0.96, 0.24), (0.86, 0.26)], gold, segments=72, closed=True, matrix=turn),
    ]
    parts += swirl_parts("Face", 0.82, place((0, -0.2, 0)))
    hand = toon((255, 236, 150), shadow=(206, 130, 40), gloss=1.0)
    # Hands from the centre: Ry(a) turns the box's +Z length toward (sin a, cos a) on the face
    # (hour hand -> 2 o'clock, minute hand -> just before 12); each box centre sits half a length out.
    for name, angle, length, width in (("HandHour", 60, 0.42, 0.09), ("HandMinute", -20, 0.6, 0.075)):
        a = math.radians(angle)
        middle = (math.sin(a) * length / 2, -0.37, math.cos(a) * length / 2)
        parts.append(rounded_box(name, (width, 0.05, length), hand, radius=0.022, matrix=place(middle, (0, angle, 0))))
    parts.append(lathe("Crown", [(0, 1.0), (0.14, 1.0), (0.16, 1.1), (0.16, 1.22), (0.12, 1.28), (0, 1.28)], gold, segments=24))
    parts.append(sweep_arc("Bow", 0.22, -60, 240, circle_section(0.06, 12), gold, steps=36, cap=True, matrix=place((0, 0, 1.46))))
    return transform_all(parts, place(rotation=(0, 8, 0))), {"yaw": 18, "pitch": 10}


def build_bone_bundle():
    """_BoneBundle part (TimeTravelerPack): three bones fanned and tied with a red ribbon band."""
    parts = []
    for index, tilt in enumerate((-58, -36, -14)):
        parts += bone_parts(f"Bundle{index}", place((0, 0.2 * (1 - index), 0), (0, tilt, 0)), length=1.8, radius=0.22, knob=0.31)
    # The ribbon loop wraps the bundle: sweep_arc draws a ring whose normal is +Y; Rz(-90) turns
    # that normal to +X, then Ry(-36) lines it up with the bundle's average direction.
    band = place(rotation=(0, -36, 0)) @ place(rotation=(0, 0, -90))
    parts.append(sweep_arc("Ribbon", 0.4, 0, 360, rounded_section(0.1, 0.3, corner=0.4), toon(TOY_RED, gloss=0.9), steps=48, cap=False, matrix=band))
    return parts, {"yaw": 20, "pitch": 14}


def build_ptero_egg():
    """
    _PteroEgg part (TimeTravelerPack: the Time Ptero pet): a sky-blue egg with violet spots and a
    little crest of three soft feathers sprouting from the top.
    """
    parts = egg_parts("PteroEgg", shell=(150, 214, 255), spot=(150, 96, 230), shadow=(96, 130, 210))
    for index, (angle, color) in enumerate(((-28, ORANGE), (0, YELLOW), (28, PINK))):
        a = math.radians(angle)
        center = (math.sin(a) * 0.36 - 0.14, 0.05, 0.86 + math.cos(a) * 0.36)
        parts.append(sphere(f"Feather{index}", 0.36, toon(color, gloss=0.6), matrix=place(center, (0, angle - 10, 0)), segments=24, rings=12, scale=(0.32, 0.18, 1.0)))
    return parts, {"yaw": 20, "pitch": 12}


# ---------------------------------------------------------------------------------------------
# Moon Base (World 3, owner R70; spec docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md
# §2.1 / §2.7) + the Lucky Button (owner R69, §1).
#
# Palette: Moon Rocks lilac (WorldsConfig colour 196, 180, 255) with a deep violet shadow and a
# near-white light, Star Shards cyan (120, 230, 255), moon-dust grey-lilac for the moon itself,
# toy red / white rockets, a pale-blue bubble helmet. Kid rules: a smiling moon, a corgi in a bubble
# helmet, nothing scary. Who uses the icons: docs/icons.md "Moon Base + Lucky Button icons (W1b)".
# ---------------------------------------------------------------------------------------------

MOON_LILAC = (196, 180, 255)
MOON_SHADOW = (104, 84, 192)
MOON_LIGHT = (242, 236, 255)
# A bluer lilac for every other rock in a heap (neighbours separate at 40 px, like BONE_TAN).
MOON_LILAC_ALT = (172, 176, 255)
MOON_CRATER = (138, 116, 220)
SHARD_CYAN = (120, 230, 255)
SHARD_DEEP = (40, 128, 214)
SHARD_LIGHT = (232, 252, 255)
# The moon itself: soft grey-lilac moon dust (rocks are the saturated lilac).
MOON_DUST = (214, 206, 236)
MOON_DUST_SHADOW = (128, 116, 178)
CORGI_ORANGE = (238, 150, 64)
CORGI_SHADOW = (186, 92, 52)
LUCKY_GREEN = (90, 236, 96)


def _hash01(*values):
    """
    A deterministic pseudo-random number in [0, 1) from a few numbers (renders stay reproducible:
    no RNG anywhere in this file). Example: _hash01(0.5, 0.25, 3) --> 0.71...
    """
    x = math.sin(sum(v * k for v, k in zip(values, (12.9898, 78.233, 37.719, 4.581)))) * 43758.5453
    return x - math.floor(x)


def _align_y(normal):
    """A rotation matrix turning local +Y onto `normal` (crater discs lie on a surface)."""
    return Vector(normal).normalized().to_track_quat("Y", "Z").to_matrix().to_4x4()


def glint(name, size, location, color=SHARD_LIGHT, shadow=SHARD_CYAN, light=WHITE, depth=0.08):
    """
    A chunky 4-point glint star facing the viewer (Moon set: cyan / white; sparkle() is amber).
    Example: glint("Glint", 0.3, (0.8, -0.9, 0.6))
    """
    outline = star_outline(4, size, size * 0.3, rotation=90.0)
    material = toon(color, shadow=shadow, light=light, gloss=0.7, rim=0.2)
    return prism(name, outline, depth, material, bevel=depth * 0.3, matrix=place(location))


def rock_parts(prefix, matrix=None, radius=1.0, seed=0, tone=MOON_LILAC, craters=2, speck=True):
    """
    One chunky faceted moon rock: an icosphere (2 subdivisions) whose vertices are pushed in / out
    by a deterministic hash (seed varies the shape), squashed a little (wider than tall), flat-shaded
    facets; `craters` darker dimple discs on its front (no hull: they read sunk into the rock) and
    an optional glowing cyan speck. The rock rests with its bottom near z = -0.84 * radius.
    Example: rock_parts("Rock", place((0, 0, 0), (0, 0, 20)), seed=3)
    """
    base = matrix if matrix is not None else Matrix.Identity(4)
    squash = Vector((1.06, 0.92, 0.84))
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=2, radius=1.0)
    for vert in bm.verts:
        n = vert.co.normalized()
        bump = 0.84 + 0.28 * _hash01(round(n.x, 3), round(n.y, 3), round(n.z, 3), seed)
        vert.co = Vector((n.x * squash.x, n.y * squash.y, n.z * squash.z)) * radius * bump
    material = toon(tone, shadow=MOON_SHADOW, light=MOON_LIGHT, gloss=0.65, rim=0.35)
    parts = [_object(f"{prefix}Rock", bm, material, sharp_angle=20, matrix=base)]
    crater = toon(MOON_CRATER, shadow=MOON_SHADOW, light=MOON_LILAC, gloss=0.2, rim=0.1)
    # Crater directions on the front (-Y) half, spread by the seed; each sits a hair inside the
    # mean surface so the rock's facets frame it.
    for index in range(craters):
        yaw = math.radians(-50 + 100 * _hash01(seed, index, 1.7))
        lift = math.radians(-10 + 50 * _hash01(seed, index, 4.3))
        d = Vector((math.sin(yaw) * math.cos(lift), -math.cos(yaw) * math.cos(lift), math.sin(lift)))
        surface = Vector((d.x * squash.x, d.y * squash.y, d.z * squash.z)) * radius * 0.94
        size = radius * (0.13 + 0.07 * _hash01(seed, index, 9.1))
        frame = base @ Matrix.Translation(surface) @ _align_y(d)
        parts.append(no_hull(sphere(f"{prefix}Crater{index}", size, crater, matrix=frame, segments=24, rings=12, scale=(1.0, 0.22, 1.0))))
    if speck:
        d = Vector((0.36, -0.55, 0.72)).normalized()
        surface = Vector((d.x * squash.x, d.y * squash.y, d.z * squash.z)) * radius * 0.98
        parts.append(sphere(f"{prefix}Speck", radius * 0.13, glow(SHARD_CYAN, light=WHITE), matrix=base @ Matrix.Translation(surface), segments=20, rings=10))
    return parts


def build_moon_rocks():
    """
    MoonRocks (Moon Base currency): one chunky faceted lilac moon rock with two crater dimples, a
    glowing cyan speck and a white-cyan glint star by its top. Reads "space rock", not "gem".
    """
    parts = rock_parts("Moon", place(rotation=(0, -12, 0)), seed=2, craters=3)
    parts.append(glint("Glint", 0.34, (0.92, -1.0, 0.82)))
    return parts, {"yaw": 22, "pitch": 16}


def shard_parts(prefix, matrix=None, size=1.0):
    """
    One Star Shard: a fat five-point star of cut cyan crystal (chamfered edges = facets, a pale
    centre facet) — the Moon rebirth token. Faces the viewer (-Y).
    """
    base = matrix if matrix is not None else Matrix.Identity(4)
    crystal = toon(SHARD_CYAN, shadow=SHARD_DEEP, light=SHARD_LIGHT, gloss=1.0, rim=0.25)
    face = toon(SHARD_LIGHT, shadow=SHARD_CYAN, light=WHITE, gloss=1.0, rim=0.1)
    outline = star_outline(5, size, size * 0.5, rotation=90.0)
    parts = [prism(f"{prefix}Star", outline, size * 0.42, crystal, bevel=size * 0.16, segments=1, matrix=base)]
    inner = star_outline(5, size * 0.5, size * 0.25, rotation=90.0)
    parts.append(no_hull(prism(f"{prefix}Facet", inner, size * 0.06, face, bevel=size * 0.02, segments=1, matrix=base @ place((0, -size * 0.24, 0)))))
    return parts


def build_star_shards():
    """
    StarShards (Moon rebirth token): a chunky cyan crystal star tilted a little, two small diamond
    shards breaking off it and a white glint (cyan + faceted: never confused with the gold Star).
    """
    parts = shard_parts("Shard", place(rotation=(0, 12, 0)))
    crystal = toon(SHARD_CYAN, shadow=SHARD_DEEP, light=SHARD_LIGHT, gloss=1.0, rim=0.25)
    for index, (x, z, s, turn) in enumerate(((1.02, -0.66, 0.24, 20), (-1.0, -0.74, 0.18, -16))):
        diamond = star_outline(4, s, s * 0.55, rotation=90.0)
        parts.append(prism(f"Bit{index}", diamond, s * 0.5, crystal, bevel=s * 0.12, segments=1, matrix=place((x, -0.1, z), (0, turn, 0))))
    parts.append(glint("Glint", 0.32, (0.78, -0.5, 0.92)))
    return parts, {"yaw": 20, "pitch": 12}


def rocket_parts(prefix, matrix=None, flame=True):
    """
    A chunky cartoon rocket standing on its tail (+Z up, bottom at z = 0): a round white body, a
    toy-red nose cone and three red fins, a blue porthole with a gold rim facing the viewer and an
    optional orange / yellow glow flame below. Used by MoonRocket and the WorldMoon tab.
    """
    base = matrix if matrix is not None else Matrix.Identity(4)
    white = toon(WHITE, shadow=(170, 170, 214), gloss=0.9)
    red = toon(TOY_RED, shadow=DARK_RED, gloss=1.0)
    parts = [
        lathe(f"{prefix}Body", [(0, 0.2), (0.42, 0.2), (0.52, 0.42), (0.58, 0.9), (0.56, 1.38), (0.5, 1.6), (0, 1.6)], white, segments=48, matrix=base),
        lathe(f"{prefix}Nose", [(0, 1.56), (0.5, 1.56), (0.46, 1.84), (0.32, 2.1), (0.14, 2.28), (0, 2.32)], red, segments=48, matrix=base),
        lathe(f"{prefix}Tail", [(0, 0.08), (0.36, 0.08), (0.44, 0.2), (0.42, 0.3), (0, 0.3)], toon(STEEL, gloss=0.9), segments=32, matrix=base),
    ]
    fin = [(0.4, 0.2), (0.96, -0.06), (0.98, 0.3), (0.54, 0.86)]
    for index in range(3):
        parts.append(prism(f"{prefix}Fin{index}", fin, 0.12, red, bevel=0.03, matrix=base @ place(rotation=(0, 0, 90 + 120 * index))))
    # Porthole on the front (-Y): Rx(90) turns the lathe's +Z toward the viewer.
    window = base @ place((0, -0.5, 1.08), (90, 0, 0))
    parts.append(lathe(f"{prefix}Window", [(0, 0.0), (0.22, 0.0), (0.21, 0.08), (0, 0.1)], toon(SKY_BLUE, shadow=DEEP_BLUE, light=(220, 240, 255), gloss=1.0), segments=32, matrix=window))
    parts.append(lathe(f"{prefix}Rim", [(0.2, -0.02), (0.29, -0.02), (0.29, 0.08), (0.2, 0.08)], toon(GOLD, gloss=1.0), segments=32, closed=True, matrix=window))
    if flame:
        parts.append(lathe(f"{prefix}Flame", [(0, -0.62), (0.16, -0.4), (0.3, -0.12), (0.32, 0.06), (0, 0.06)], glow(ORANGE, light=(255, 230, 160)), segments=32, matrix=base))
        parts.append(lathe(f"{prefix}FlameCore", [(0, -0.36), (0.1, -0.2), (0.18, 0.0), (0, 0.08)], glow(YELLOW, light=WHITE), segments=24, matrix=base @ place((0, -0.12, 0))))
    return parts


def build_moon_rocket():
    """
    MoonRocket (the lobby rocket portal to Moon Base; WORLD UNLOCKED popup, portal prompts — like
    TimeMachine for Dino): the cartoon rocket lifting off a round lilac launch pad with a yellow
    hazard band, leaning a little, flame on.
    """
    pad = toon(MOON_LILAC, shadow=MOON_SHADOW, light=MOON_LIGHT, gloss=0.6)
    band = toon(YELLOW, shadow=(220, 140, 40), gloss=0.8)
    parts = [
        lathe("Pad", [(0, 0.0), (1.2, 0.0), (1.26, 0.1), (1.2, 0.22), (0, 0.22)], pad, segments=64),
        lathe("PadBand", [(0.9, 0.2), (1.08, 0.2), (1.08, 0.26), (0.9, 0.26)], band, segments=64, closed=True),
    ]
    parts += rocket_parts("Rocket", place((0.06, 0, 0.7), (0, 8, 0)))
    return parts, {"yaw": 22, "pitch": 14}


def build_world_moon():
    """
    WorldMoon (world tab: Moon Base): a smiling cartoon moon — a round grey-lilac moon-dust ball
    with crater dimples, big friendly eyes, a smile and pink cheeks — with a little red / white
    rocket zooming past its upper right (flame on). Nothing scary.
    """
    dust = toon(MOON_DUST, shadow=MOON_DUST_SHADOW, light=WHITE, gloss=0.6, rim=0.4)
    crater = toon((176, 164, 214), shadow=MOON_DUST_SHADOW, light=MOON_DUST, gloss=0.2, rim=0.1)
    parts = [sphere("Moon", 1.0, dust, segments=64, rings=32)]
    for index, (x, z, r) in enumerate(((-0.56, 0.5, 0.2), (0.62, -0.36, 0.16), (-0.18, -0.68, 0.13), (0.3, 0.74, 0.11), (-0.8, -0.18, 0.12))):
        d = Vector((x, -math.sqrt(max(0.05, 1 - x * x - z * z)), z))
        frame = Matrix.Translation(d * 0.985) @ _align_y(d)
        parts.append(no_hull(sphere(f"Crater{index}", r, crater, matrix=frame, segments=24, rings=12, scale=(1.0, 0.24, 1.0))))
    parts += eyes("Moon", [(-0.3, -0.88, 0.16), (0.3, -0.88, 0.16)], 0.17)
    smile = [(-0.24 + 0.06 * i, -0.2 - 0.1 * (1 - ((-0.24 + 0.06 * i) / 0.24) ** 2)) for i in range(9)]
    parts.append(sweep_path("Smile", smile, [0.04] * len(smile), toon((70, 60, 110), gloss=0.2, rim=0.1), segments=10, matrix=place((0, -0.97, 0))))
    blush = toon((255, 160, 196), shadow=(230, 120, 160), gloss=0.0, rim=0.0)
    for index, x in enumerate((-0.52, 0.52)):
        parts.append(no_hull(sphere(f"Blush{index}", 0.13, blush, matrix=place((x, -0.83, -0.12), (0, 0, 30 if x > 0 else -30)), segments=20, rings=10, scale=(1.0, 0.3, 0.7))))
    rocket = rocket_parts("Mini", place((1.02, -0.4, 0.62), (0, 38, 0), 0.42))
    return parts + rocket, {"yaw": 18, "pitch": 12}


# Rock-heap layouts: (x, z, radius, depth y) per rock, drawn back to front; rows shrink upward.
#   medium = a 3-2-1 heap of six;  large = a 4-3-2-1 heap of ten (+ star shards and glints).
ROCK_HEAPS = {
    "medium": (
        (-1.2, 0.0, 0.62, 0.5), (0.0, 0.0, 0.66, 0.5), (1.2, 0.0, 0.6, 0.5),
        (-0.6, 0.86, 0.56, 0.1), (0.62, 0.86, 0.58, 0.1),
        (0.0, 1.66, 0.52, -0.3),
    ),
    "large": (
        (-1.8, 0.0, 0.6, 0.7), (-0.6, 0.0, 0.64, 0.7), (0.62, 0.0, 0.62, 0.7), (1.82, 0.0, 0.58, 0.7),
        (-1.2, 0.84, 0.58, 0.3), (0.0, 0.84, 0.6, 0.3), (1.2, 0.84, 0.56, 0.3),
        (-0.6, 1.64, 0.54, -0.1), (0.62, 1.64, 0.56, -0.1),
        (0.0, 2.4, 0.5, -0.5),
    ),
}


def rock_heap(size):
    """A stacked heap of moon rocks (ROCK_HEAPS[size]) alternating lilac / bluer lilac."""
    parts = []
    for index, (x, z, radius, y) in enumerate(ROCK_HEAPS[size]):
        tone = MOON_LILAC_ALT if index % 2 else MOON_LILAC
        spin = place((x, y, z), (0, -18 + 37 * _hash01(index, 2.2), 0))
        parts += rock_parts(f"Heap{index}", spin, radius=radius, seed=index + 7, tone=tone, craters=1, speck=index % 3 == 0)
    return parts


def build_moon_rocks_pack_small():
    """MoonRocksPackSmall ('Bag of Moon Rocks'): three moon rocks in a little 2-1 stack."""
    parts = []
    for index, (x, y, z, r) in enumerate(((-0.64, 0.3, 0.0, 0.66), (0.66, 0.3, 0.0, 0.62), (0.02, -0.1, 0.86, 0.6))):
        tone = MOON_LILAC_ALT if index == 1 else MOON_LILAC
        parts += rock_parts(f"Trio{index}", place((x, y, z), (0, 10 - 20 * index, 0)), radius=r, seed=index + 3, tone=tone, craters=2, speck=index == 2)
    return parts, {"yaw": 20, "pitch": 14}


def build_moon_rocks_pack():
    """MoonRocksPack ('Sack of Moon Rocks', medium): a 3-2-1 heap of six rocks with one glint."""
    parts = rock_heap("medium") + [glint("Glint", 0.4, (1.0, -0.9, 2.1))]
    return parts, {"yaw": 20, "pitch": 16}


def build_moon_rocks_pack_large():
    """
    MoonRocksPackLarge ('Crate of Moon Rocks'): a big 4-3-2-1 heap of ten rocks with three cyan
    star shards tucked into the front and two glints (the 'jackpot' read, like BonesPackLarge).
    """
    parts = rock_heap("large")
    for index, (x, z, s, turn) in enumerate(((-1.2, 0.2, 0.42, -14), (1.24, 0.2, 0.42, 16), (0.0, 1.0, 0.4, 6))):
        parts += shard_parts(f"Shard{index}", place((x, -0.86, z), (0, turn, 0), s))
    parts.append(glint("Glint0", 0.46, (1.24, -1.0, 2.84)))
    parts.append(glint("Glint1", 0.34, (-1.66, -1.0, 2.04)))
    return parts, {"yaw": 20, "pitch": 16}


def build_moon_rock_trio():
    """_MoonRockTrio part (AstronautPack): the three-rock stack of MoonRocksPackSmall."""
    return build_moon_rocks_pack_small()


def build_corgi_helmet():
    """
    _CorgiHelmet part (AstronautPack: the Rocket Corgi pet): a cute corgi face inside a pale-blue
    bubble helmet with a white collar ring and a gold band. The face sits in front of the glass
    ball so the ball reads as a bubble around it; a white glass glint (no hull) sells the glass.
    """
    glass = toon(GLASS, shadow=(120, 166, 230), light=WHITE, gloss=1.0, rim=0.5)
    white = toon(WHITE, shadow=(170, 170, 214), gloss=0.9)
    gold = toon(GOLD, shadow=(206, 110, 40), light=(255, 240, 170), gloss=1.0)
    parts = [
        sphere("Bubble", 1.0, glass, matrix=place((0, 0.2, 1.08)), segments=64, rings=32),
        lathe("Collar", [(0, 0.0), (0.92, 0.0), (1.02, 0.1), (1.0, 0.3), (0.86, 0.4), (0, 0.4)], white, segments=64),
        lathe("Band", [(0.98, 0.14), (1.06, 0.14), (1.06, 0.26), (0.98, 0.26)], gold, segments=64, closed=True),
    ]
    fur = toon(CORGI_ORANGE, shadow=CORGI_SHADOW, light=(255, 210, 150), gloss=0.6)
    cream = toon(CREAM, shadow=(214, 176, 140), light=WHITE, gloss=0.6)
    inner_ear = toon((255, 168, 176), shadow=(220, 120, 140), gloss=0.3)
    face = place((0, -0.78, 1.0))
    parts.append(sphere("Head", 0.56, fur, matrix=face, segments=48, rings=24, scale=(1.08, 0.5, 0.92)))
    parts.append(sphere("Blaze", 0.34, cream, matrix=face @ place((0, -0.12, -0.18)), segments=32, rings=16, scale=(1.1, 0.5, 0.86)))
    for index, side in enumerate((-1, 1)):
        ear = [(-0.2, 0.0), (0.2, 0.0), (0.04, 0.52)]
        tip = place((side * 0.36, 0.06, 0.38), (0, side * -16, 0))
        parts.append(prism(f"Ear{index}", ear, 0.12, fur, bevel=0.04, matrix=face @ tip))
        inner = [(-0.11, 0.06), (0.11, 0.06), (0.03, 0.38)]
        parts.append(no_hull(prism(f"EarIn{index}", inner, 0.04, inner_ear, matrix=face @ tip @ place((0, -0.07, 0)))))
    parts += eyes("Corgi", [(-0.2, -1.04, 1.1), (0.2, -1.04, 1.1)], 0.11)
    parts.append(sphere("Nose", 0.07, toon((40, 30, 40), gloss=1.0, rim=0.1), matrix=place((0, -1.1, 0.9)), segments=20, rings=10, scale=(1.3, 0.8, 0.9)))
    mouth = [(-0.12 + 0.03 * i, -0.06 * (1 - ((-0.12 + 0.03 * i) / 0.12) ** 2)) for i in range(9)]
    parts.append(sweep_path("Mouth", mouth, [0.022] * len(mouth), toon((70, 40, 40), gloss=0.2, rim=0.1), segments=8, matrix=place((0, -1.08, 0.82))))
    parts.append(no_hull(sphere("Tongue", 0.06, toon(PINK, gloss=0.6), matrix=place((0.02, -1.07, 0.74)), segments=16, rings=8, scale=(1.0, 0.4, 1.2))))
    parts.append(no_hull(sphere("GlassGlint", 0.13, toon(WHITE, gloss=0.0, rim=0.0), matrix=place((-0.58, -0.62, 1.66), (0, -30, 0)), segments=16, rings=8, scale=(1.0, 0.3, 1.8))))
    return parts, {"yaw": 18, "pitch": 12}


def build_lucky_button():
    """
    LuckyButton (owner R69 Lucky Buttons: toasts, admin, the HUD arrow): a chunky round arcade
    button — dark navy housing, gold bezel, a big glossy glowing lucky-green dome with a gold star
    stamped on its front — and two white-gold glints. Seen a little more from above so the dome reads.
    """
    housing = toon(NAVY, shadow=(24, 26, 60), light=(110, 130, 200), gloss=0.8)
    gold = toon(GOLD, shadow=(206, 110, 40), light=(255, 240, 170), gloss=1.0)
    dome = toon(LUCKY_GREEN, shadow=(30, 160, 80), light=(220, 255, 200), gloss=1.0, rim=0.25)
    parts = [
        lathe("Housing", [(0, 0.0), (1.12, 0.0), (1.2, 0.1), (1.16, 0.34), (1.02, 0.42), (0, 0.42)], housing, segments=64),
        lathe("Bezel", [(0.8, 0.36), (1.02, 0.36), (1.04, 0.46), (0.98, 0.54), (0.8, 0.54)], gold, segments=64, closed=True),
        lathe("Dome", [(0, 0.4), (0.82, 0.4), (0.84, 0.56), (0.76, 0.84), (0.52, 1.04), (0.24, 1.12), (0, 1.14)], dome, segments=64),
    ]
    # The star sits proud of the dome's front slope (the slope's surface is at y ~ -0.66 there),
    # tilted back to follow it.
    star = star_outline(5, 0.36, 0.17, rotation=90.0)
    parts.append(prism("Star", star, 0.1, toon(YELLOW, shadow=(226, 140, 40), light=(255, 248, 190), gloss=0.9), bevel=0.03, matrix=place((0, -0.76, 0.9), (-36, 0, 0))))
    parts.append(glint("Glint0", 0.26, (0.98, -0.8, 1.22), color=WHITE, shadow=(255, 230, 140), light=WHITE))
    parts.append(glint("Glint1", 0.18, (-1.04, -0.8, 0.98), color=WHITE, shadow=(255, 230, 140), light=WHITE))
    return parts, {"yaw": 22, "pitch": 28}


BUILDERS = {
    "Close": build_close,
    "Arrow": build_arrow,
    "Robux": build_robux,
    "Nuke": build_nuke,
    "MegaLauncher": build_mega_launcher,
    "Egg": build_egg,
    "Cash": build_cash,
    "LuckyWheel": build_lucky_wheel,
    "Rebirth": build_rebirth,
    "RebirthToken": build_rebirth_token,
    "Acorn": build_acorn,
    "Chest": build_chest,
    "Potion": build_potion,
    "Upgrade": build_upgrade,
    "Crate": build_crate,
    "AATower": build_aa_tower,
    "Sticker": build_sticker,
    "Shop": build_shop,
    "Daily": build_daily,
    "Area02": build_stand,
    "Area10": build_facility,
    "_NukeBlue": build_nuke_blue,
    "_NukeGreen": build_nuke_green,
    "_TorchHandle": build_torch_handle,
    "_PlusBadge": build_plus_badge,
    # Harvest Feast (event)
    "GobbleBomb": build_gobble_bomb,
    "HarvestEgg": build_harvest_egg,
    "DecorHayBales": build_hay_bales,
    "DecorPumpkinPile": build_pumpkin_pile,
    "DecorScarecrow": build_scarecrow,
    "DecorCornucopia": build_cornucopia,
    "DecorGarland": build_garland,
    "_RoastTurkey": build_roast_turkey,
    "_AcornBuddy": build_acorn_buddy,
    "_Pedestal": build_pedestal,
    # Dino Valley (World 2, owner R57).
    "Bones": build_bones,
    "Amber": build_amber,
    "WorldNukeTown": build_world_nuke_town,
    "WorldDino": build_world_dino,
    "TimeMachine": build_time_machine,
    "BonesPackSmall": build_bones_pack_small,
    "BonesPack": build_bones_pack,
    "BonesPackLarge": build_bones_pack_large,
    "_PocketWatch": build_pocket_watch,
    "_BoneBundle": build_bone_bundle,
    "_PteroEgg": build_ptero_egg,
    # Moon Base (World 3, owner R70) + the Lucky Button (owner R69): W1b.
    "MoonRocks": build_moon_rocks,
    "StarShards": build_star_shards,
    "WorldMoon": build_world_moon,
    "MoonRocket": build_moon_rocket,
    "MoonRocksPackSmall": build_moon_rocks_pack_small,
    "MoonRocksPack": build_moon_rocks_pack,
    "MoonRocksPackLarge": build_moon_rocks_pack_large,
    "LuckyButton": build_lucky_button,
    "_MoonRockTrio": build_moon_rock_trio,
    "_CorgiHelmet": build_corgi_helmet,
}


# ---------------------------------------------------------------------------------------------
# Scene, framing, render
# ---------------------------------------------------------------------------------------------


def reset_scene():
    """Empty factory scene with a transparent EEVEE film and exact (Standard) colour output."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _MATERIALS.clear()
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = RENDER_SIZE
    scene.render.resolution_y = RENDER_SIZE
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0
    scene.view_settings.gamma = 1
    scene.eevee.taa_render_samples = 64
    world = bpy.data.worlds.new("World")
    world.color = (0, 0, 0)
    scene.world = world
    return scene


def add_light(scene):
    """The key sun light (shading only: no cast shadows; crease AO gives contact shading)."""
    data = bpy.data.lights.new("Key", "SUN")
    data.energy = 3.2
    data.angle = math.radians(8)
    data.use_shadow = False
    light = bpy.data.objects.new("Key", data)
    light.rotation_euler = (-LIGHT_DIRECTION).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(light)


def add_camera(scene, yaw, pitch):
    """Orthographic camera on the 3/4 view direction (yaw right of front, pitch above)."""
    data = bpy.data.cameras.new("Camera")
    data.type = "ORTHO"
    data.clip_start = 0.1
    data.clip_end = 100
    camera = bpy.data.objects.new("Camera", data)
    y, p = math.radians(yaw), math.radians(pitch)
    direction = Vector((math.sin(y) * math.cos(p), -math.cos(y) * math.cos(p), math.sin(p)))
    camera.location = direction * 20
    camera.rotation_euler = (-direction).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(camera)
    scene.camera = camera
    return camera


def frame(camera, parts):
    """
    Fits the ortho camera to the parts' projected bounds so every icon fills the same box:
    FINAL_SIZE - 2 * (OUTLINE_PX + HULL_PX + PAD_PX) px of the final image, centred.
    In an ortho camera the frame spans ortho_scale world units; shift is in ortho_scale units.
    """
    bpy.context.view_layer.update()
    inverse = camera.matrix_world.inverted()
    xs, ys = [], []
    for obj in parts:
        world = obj.matrix_world
        for vert in obj.data.vertices:
            local = inverse @ (world @ vert.co)
            xs.append(local.x)
            ys.append(local.y)
    width, height = max(xs) - min(xs), max(ys) - min(ys)
    usable = (FINAL_SIZE - 2 * (OUTLINE_PX + HULL_PX + PAD_PX)) / FINAL_SIZE
    camera.data.ortho_scale = max(width, height) / usable
    camera.data.shift_x = (max(xs) + min(xs)) / 2 / camera.data.ortho_scale
    camera.data.shift_y = (max(ys) + min(ys)) / 2 / camera.data.ortho_scale
    return camera.data.ortho_scale


def add_hulls(parts, ortho_scale):
    """
    Inverted-hull inner lines: HULL_PX of the final image, converted to world units.
    A part flagged with `no_hull(obj)` is skipped: it reads as painted on / sunk INTO the surface
    it sits on (the fern fossil inside the Amber gem, soft cheek blush) instead of a separate piece.
    """
    outline = outline_material()
    thickness = HULL_PX * ortho_scale / FINAL_SIZE
    for obj in parts:
        if obj.get("no_hull"):
            continue
        obj.data.materials.append(outline)
        hull = obj.modifiers.new("Hull", "SOLIDIFY")
        hull.thickness = thickness
        hull.offset = 1
        hull.use_flip_normals = True
        hull.use_rim = False
        # Even thickness divides by the corner angle's cosine: on thin parts (basket holes, awning
        # slats, text, trefoil blades) that spikes into long black shards. Plain offset + quality
        # normals keeps a uniform, artefact-free line.
        hull.use_even_offset = False
        hull.use_quality_normals = True
        hull.material_offset = 1


def render(name, out_dir):
    """Builds, frames and renders one icon to <out_dir>/<name>.png (raw pass, before the outline)."""
    scene = reset_scene()
    add_light(scene)
    parts, view = BUILDERS[name]()
    camera = add_camera(scene, view.get("yaw", DEFAULT_YAW), view.get("pitch", DEFAULT_PITCH))
    ortho_scale = frame(camera, parts)
    add_hulls(parts, ortho_scale)
    scene.render.filepath = os.path.join(out_dir, f"{name}.png")
    bpy.ops.render.render(write_still=True)
    print(f"RENDERED {name} -> {scene.render.filepath}")


def main():
    """Entry: `-- <out_dir> [Name ...]` after Blender's own arguments (names validated)."""
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if not argv:
        raise SystemExit("usage: blender --background --factory-startup --python render_icons.py -- <out_dir> [Name ...]")
    out_dir = os.path.abspath(argv[0])
    names = argv[1:] or list(BUILDERS)
    for name in names:
        if name not in BUILDERS:
            raise SystemExit(f"unknown icon {name!r}; expected one of {sorted(BUILDERS)}")
    os.makedirs(out_dir, exist_ok=True)
    for name in names:
        render(name, out_dir)


if __name__ == "__main__":
    main()
