"""
render_brand.py — SellNukes brand renders: the "SELL NUKES" logo, the Nukey mascot and the hub
key-art scene (owner brand package, 2026-10-30). Store thumbnails + the experience icon moved to
ForgeGUI (owner R23, lead: assets/marketing/2026-10-30-forgegui/).

Purpose:
    The logo and mascot share the icon set's soft-toon look (tools/blender/ui_icons/render_icons.py:
    eased 3-tone ramp, specular blob, inner hull lines; the thick outer outline is added in post by
    tools/ui/brand/brand.py). The hub key art is a lit, stud-textured 3D scene staged from B4's REAL
    uploaded world models (assets/blender/world/*.glb).

Renders (raw passes; brand.py does outline / captions / composition / sizes):
    Logo     "SELL" over "NUKES" in Luckiest Guy (Apache-2.0, assets/brand/fonts), one candy colour
             per letter with embossed studs, Nukey leaning in on the left and a yellow radiation
             trefoil badge after "SELL". Transparent, 4096 x 2304.
    Nukey    the mascot (A8_MascotNukey.glb) in the toon style. Transparent, 2048 x 2048.
    Hub      the hub lobby (plaza + monument ringed by 8 plot gates with builds): the
             loading-screen key art. Rendered 2x, downsampled by brand.py.

How it connects:
    tools/ui/brand/brand.py runs this (`render`), then outlines / composes / uploads, and writes
    src/shared/Config/BrandAssets.luau + src/first/LoadingScreen/BrandImages.luau. Nothing in the
    game loads this file.

Usage:
    blender --background --factory-startup --python-exit-code 1 \
        --python tools/blender/ui_icons/render_brand.py -- <out_dir> <font.ttf> <world_dir> [Name ...] [--preview]

Coordinates: Z up. Imported glTF models keep their stud units (1 Blender unit = 1 stud).
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_icons as ri  # noqa: E402  (shared toon materials, geometry helpers, hulls)

PREVIEW = "--preview" in sys.argv

# Candy colours, one per letter (S E L L / N U K E S).
LETTER_COLORS = (
    (240, 64, 60),
    (255, 146, 40),
    (255, 206, 40),
    (110, 210, 60),
    (60, 170, 240),
    (150, 96, 230),
    (255, 110, 180),
    (120, 220, 70),
    (255, 160, 40),
)


# ---------------------------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------------------------


def import_glb(path, matrix=Matrix()):
    """Imports a glTF model and bakes `matrix` into its meshes; returns the new mesh objects."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    meshes = []
    for obj in new:
        if obj.type == "MESH":
            world = obj.matrix_world.copy()
            obj.parent = None
            obj.data = obj.data.copy()
            obj.data.transform(world)
            obj.matrix_world = Matrix()
            obj.data.transform(matrix)
            meshes.append(obj)
    for obj in new:
        if obj.type != "MESH":
            bpy.data.objects.remove(obj)
    return meshes


def base_color(material):
    """(r, g, b) 0..255 sRGB + emission strength of an imported glTF material."""
    if material is None or material.node_tree is None:
        return (200, 200, 200), 0.0
    bsdf = next((n for n in material.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None:
        return (200, 200, 200), 0.0
    linear = bsdf.inputs["Base Color"].default_value[:3]

    def to_srgb(c):
        return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055

    emission = 0.0
    if "Emission Strength" in bsdf.inputs:
        color = bsdf.inputs["Emission Color"].default_value[:3]
        emission = bsdf.inputs["Emission Strength"].default_value * max(color)
    return tuple(round(max(0.0, min(1.0, to_srgb(c))) * 255) for c in linear), emission


def clip_below(objects, height):
    """Deletes faces lying entirely below `height` (the mascot statue's pedestal + name plaque)."""
    kept = []
    for obj in objects:
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        doomed = [f for f in bm.faces if max(v.co.z for v in f.verts) < height]
        bmesh.ops.delete(bm, geom=doomed, context="FACES")
        bm.to_mesh(obj.data)
        bm.free()
        if len(obj.data.polygons) == 0:
            bpy.data.objects.remove(obj)
        else:
            kept.append(obj)
    return kept


# Height (studs) of the A8_MascotNukey pedestal top: below it is the statue base, not Nukey.
NUKEY_BASE_TOP = 3.2

# Owner R47 ("very light colored ... like a white overlay"): the world model's own colours are
# pastel (tuned for Roblox's sunlit world: Body 255/236/122, Core 175/255/160, Nose 245/137/129),
# and the toon light tone lifts every colour 40 % toward warm white, so the 2D mascot read milky.
# Brand renders use this candy palette (keyed by glTF material name, the ".001" suffix ignored;
# unlisted materials such as Eyes / White keep their colour) and a gentler highlight mix.
NUKEY_PALETTE = {
    "Body": (255, 204, 28),  # sunny yellow (the logo's SELL yellow)
    "Core": (96, 220, 58),  # lime band (the logo's NUKES green)
    "Nose": (255, 72, 98),  # candy red-pink cap
    "Fins": (58, 128, 236),  # toy blue fins
    "Pink": (255, 112, 176),  # cheeks + lunchbox
    "Dark": (58, 60, 82),  # brows / mouth / trefoil
    "Sign": (255, 240, 200),
}
NUKEY_LIGHT_MIX = 0.2  # toon highlight: 20 % toward warm white (the shared icon default is 40 %)


def nukey_parts(world_dir, matrix=Matrix()):
    """Nukey (B4's A8_MascotNukey) without the statue pedestal, toon-shaded, `matrix` applied."""
    parts = import_glb(os.path.join(world_dir, "A8_MascotNukey.glb"))
    parts = clip_below(parts, NUKEY_BASE_TOP)
    for obj in parts:
        obj.data.transform(matrix @ Matrix.Translation((0, 0, -NUKEY_BASE_TOP)))
    toonify(parts, NUKEY_PALETTE, NUKEY_LIGHT_MIX)
    return parts


def toonify(objects, palette=None, light_mix=None):
    """
    Replaces every material on `objects` with the shared toon material of its base colour.
    @param palette   optional {material name: (r, g, b)} overrides (glTF ".001" suffixes ignored)
    @param light_mix optional highlight mix toward warm white (None = the shared 40 % default)
    Example: toonify(parts, NUKEY_PALETTE, NUKEY_LIGHT_MIX)
    """
    for obj in objects:
        for index, material in enumerate(obj.data.materials):
            color, emission = base_color(material)
            name = material.name.split(".")[0] if material is not None else ""
            if palette is not None and name in palette:
                color = palette[name]
            if emission > 0.1:
                obj.data.materials[index] = ri.glow(color)
            elif light_mix is not None:
                light = ri.mix_rgb(color, (255, 252, 235), light_mix)
                obj.data.materials[index] = ri.toon(color, light=light, gloss=0.8)
            else:
                obj.data.materials[index] = ri.toon(color, gloss=0.8)


def add_multi_hulls(parts, ortho_scale):
    """Inverted hulls for objects with several material slots (one outline slot per original)."""
    outline = ri.outline_material()
    thickness = ri.HULL_PX * ortho_scale / ri.FINAL_SIZE
    for obj in parts:
        count = len(obj.data.materials)
        for _ in range(count):
            obj.data.materials.append(outline)
        hull = obj.modifiers.new("Hull", "SOLIDIFY")
        hull.thickness = thickness
        hull.offset = 1
        hull.use_flip_normals = True
        hull.use_rim = False
        hull.use_even_offset = False
        hull.use_quality_normals = True
        hull.material_offset = count


def toon_scene(width, height):
    """Factory scene configured for a transparent toon render (same settings as the icons)."""
    scene = ri.reset_scene()
    scene.render.resolution_x = width
    scene.render.resolution_y = height
    if PREVIEW:
        scene.render.resolution_percentage = 25
        scene.eevee.taa_render_samples = 8
    ri.add_light(scene)
    return scene


def frame_to(camera, parts, aspect, margin=0.04):
    """Ortho camera fitted to the parts' projected bounds for a width/height `aspect` frame."""
    bpy.context.view_layer.update()
    inverse = camera.matrix_world.inverted()
    xs, ys = [], []
    for obj in parts:
        for vert in obj.data.vertices:
            local = inverse @ (obj.matrix_world @ vert.co)
            xs.append(local.x)
            ys.append(local.y)
    width, height = max(xs) - min(xs), max(ys) - min(ys)
    scale = max(width, height * aspect) * (1 + 2 * margin)
    camera.data.ortho_scale = scale
    camera.data.shift_x = (max(xs) + min(xs)) / 2 / scale
    camera.data.shift_y = (max(ys) + min(ys)) / 2 / scale
    return scale


# ---------------------------------------------------------------------------------------------
# Logo
# ---------------------------------------------------------------------------------------------


def split_components(obj):
    """Splits a mesh object into one object per connected component (one per glyph), left->right."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    seen, groups = set(), []
    for face in bm.faces:
        if face.index in seen:
            continue
        stack, group = [face], []
        seen.add(face.index)
        while stack:
            current = stack.pop()
            group.append(current.index)
            for edge in current.edges:
                for other in edge.link_faces:
                    if other.index not in seen:
                        seen.add(other.index)
                        stack.append(other)
        groups.append(set(group))
    pieces = []
    for index, group in enumerate(groups):
        copy = bm.copy()
        copy.faces.ensure_lookup_table()
        bmesh.ops.delete(copy, geom=[f for f in copy.faces if f.index not in group], context="FACES")
        mesh = bpy.data.meshes.new(f"{obj.name}{index}")
        copy.to_mesh(mesh)
        copy.free()
        piece = bpy.data.objects.new(mesh.name, mesh)
        bpy.context.scene.collection.objects.link(piece)
        pieces.append(piece)
    bm.free()
    bpy.data.objects.remove(obj)
    pieces.sort(key=lambda o: sum(v.co.x for v in o.data.vertices) / max(1, len(o.data.vertices)))
    return pieces


def word(text, font, size, location, depth=0.32):
    """A chunky extruded word (front faces -Y) split into per-letter objects."""
    curve = bpy.data.curves.new(text, "FONT")
    curve.body = text
    curve.font = font
    curve.size = size
    curve.extrude = depth * size / 2
    curve.offset = 0.012 * size
    curve.bevel_depth = 0.03 * size
    curve.bevel_resolution = 3
    curve.resolution_u = 10
    curve.space_character = 1.04
    curve.align_x = "CENTER"
    curve.align_y = "CENTER"
    holder = bpy.data.objects.new(text + "Curve", curve)
    bpy.context.scene.collection.objects.link(holder)
    bpy.context.view_layer.update()
    mesh = bpy.data.meshes.new_from_object(holder.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    bpy.data.objects.remove(holder)
    # Font meshes come as separate caps + sides: weld them so each glyph is ONE connected piece.
    welded = bmesh.new()
    welded.from_mesh(mesh)
    bmesh.ops.remove_doubles(welded, verts=welded.verts[:], dist=1e-4 * size)
    welded.to_mesh(mesh)
    welded.free()
    mesh.transform(Matrix.Translation(Vector(location)) @ Matrix.Rotation(math.radians(90), 4, "X"))
    obj = bpy.data.objects.new(text, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return split_components(obj)


def build_logo(font_path, world_dir, with_nukey=True):
    """The logo parts: SELL / NUKES letters, trefoil badge, Nukey (returns objects, multi-slot ones)."""
    font = bpy.data.fonts.load(font_path)
    letters = word("SELL", font, 1.0, (0.55, 0.0, 0.62)) + word("NUKES", font, 1.25, (0.35, 0.0, -0.55))
    for index, letter in enumerate(letters):
        color = LETTER_COLORS[index % len(LETTER_COLORS)]
        material = ri.toon(color, light=ri.mix_rgb(color, (255, 252, 235), 0.2), gloss=0.7, studs=(9.0, 0.6))
        letter.data.materials.append(material)
        for polygon in letter.data.polygons:
            polygon.use_smooth = True
        if hasattr(letter.data, "set_sharp_from_angle"):
            letter.data.set_sharp_from_angle(angle=math.radians(40))
    # Little tilts so the title bounces like a toy (alternating +-4 degrees about Y at each glyph).
    for index, letter in enumerate(letters):
        verts = letter.data.vertices
        cx = sum(v.co.x for v in verts) / len(verts)
        cz = sum(v.co.z for v in verts) / len(verts)
        tilt = math.radians(4 if index % 2 == 0 else -4)
        letter.data.transform(Matrix.Translation((cx, 0, cz)) @ Matrix.Rotation(tilt, 4, "Y") @ Matrix.Translation((-cx, 0, -cz)))
    # Radiation trefoil badge after "SELL".
    badge = [
        ri.lathe("Badge", [(0, -0.07), (0.3, -0.07), (0.35, 0.0), (0.3, 0.07), (0, 0.07)], ri.toon(ri.YELLOW, gloss=1.0), segments=48, matrix=ri.place((1.98, 0, 0.68), (90, 0, 0))),
    ]
    badge += ri.trefoil_parts("Trefoil", (1.98, -0.08, 0.68), 0.27, 0.05, ri.toon(ri.HAZARD_BLACK, gloss=0.3))
    # Nukey: B4's mascot model, toon-shaded, leaning in from the left.
    if not with_nukey:
        return letters + badge, []
    # 17.8 studs tall without the pedestal -> 2.1 logo units, leaning in from the left.
    scale = 2.1 / (21.0 - NUKEY_BASE_TOP)
    nukey = nukey_parts(
        world_dir,
        Matrix.Translation((-2.3, 0.1, -1.05)) @ Matrix.Rotation(math.radians(-12), 4, "Y") @ Matrix.Rotation(math.radians(200), 4, "Z") @ Matrix.Scale(scale, 4),
    )
    return letters + badge, nukey


def render_logo(out_dir, font_path, world_dir, with_nukey=True):
    """Logo raw pass (transparent 4096 x 2304); with_nukey=False = the text-only title (LogoText)."""
    scene = toon_scene(4096, 2304)
    camera = ri.add_camera(scene, 12, 8)
    single, multi = build_logo(font_path, world_dir, with_nukey)
    scale = frame_to(camera, single + multi, 2304 / 4096)
    # Letters get NO inverted hull: welded font geometry spikes the hull into black shards; the
    # post outline frames them and the letter gaps keep them apart. Badge + Nukey keep hulls.
    letters = [obj for obj in single if obj.name.startswith(("SELL", "NUKES"))]
    ri.add_hulls([obj for obj in single if obj not in letters], scale * ri.FINAL_SIZE / 4096 * 4)
    if multi:
        add_multi_hulls(multi, scale * ri.FINAL_SIZE / 4096 * 4)
    scene.render.filepath = os.path.join(out_dir, "Logo.png" if with_nukey else "LogoText.png")
    bpy.ops.render.render(write_still=True)


def render_nukey(out_dir, world_dir):
    """Nukey raw pass (transparent 2048 x 2048, toon)."""
    scene = toon_scene(2048, 2048)
    camera = ri.add_camera(scene, 18, 10)
    nukey = nukey_parts(world_dir, Matrix.Rotation(math.radians(200), 4, "Z") @ Matrix.Scale(0.1, 4))
    scale = frame_to(camera, nukey, 1.0, margin=0.08)
    add_multi_hulls(nukey, scale * 1.0)
    scene.render.filepath = os.path.join(out_dir, "Nukey.png")
    bpy.ops.render.render(write_still=True)


# ---------------------------------------------------------------------------------------------
# Lit scenes: stud-textured staging of the real world models (hub key art)
# ---------------------------------------------------------------------------------------------

_STUD_MATERIALS = {}


def stud_material(color, emission=0.0, stud=2.0, alpha=1.0):
    """
    A toy-plastic Principled material with procedural studs on axis-aligned faces (world space,
    `stud` studs per cell; triplanar by face normal) via a bump, and a soft stud-edge darkening.
    alpha < 1 = translucent "ghost" (build-in preview).
    """
    key = (color, round(emission, 2), stud, alpha)
    if key in _STUD_MATERIALS:
        return _STUD_MATERIALS[key]
    mat = bpy.data.materials.new(f"Stud{len(_STUD_MATERIALS)}")
    if bpy.app.version < (5, 0, 0):
        mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = ri.lin(color)
    bsdf.inputs["Roughness"].default_value = 0.42
    if emission > 0:
        bsdf.inputs["Emission Color"].default_value = ri.lin(color)
        bsdf.inputs["Emission Strength"].default_value = 2.0
    if alpha < 1:
        bsdf.inputs["Alpha"].default_value = alpha
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "BLENDED"
    geometry = nodes.new("ShaderNodeNewGeometry")
    scaled = nodes.new("ShaderNodeVectorMath")
    scaled.operation = "SCALE"
    links.new(geometry.outputs["Position"], scaled.inputs[0])
    scaled.inputs["Scale"].default_value = 1.0 / stud
    split = nodes.new("ShaderNodeSeparateXYZ")
    links.new(scaled.outputs[0], split.inputs[0])
    normal = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geometry.outputs["Normal"], normal.inputs[0])

    def disc(a, b):
        """Stud disc height (0/1, smoothed) on the plane spanned by components a, b."""
        centred = []
        for axis in (a, b):
            fract = nodes.new("ShaderNodeMath")
            fract.operation = "FRACT"
            links.new(split.outputs[axis], fract.inputs[0])
            minus = nodes.new("ShaderNodeMath")
            minus.operation = "SUBTRACT"
            links.new(fract.outputs[0], minus.inputs[0])
            minus.inputs[1].default_value = 0.5
            centred.append(minus.outputs[0])
        joined = nodes.new("ShaderNodeCombineXYZ")
        links.new(centred[0], joined.inputs[0])
        links.new(centred[1], joined.inputs[1])
        length = nodes.new("ShaderNodeVectorMath")
        length.operation = "LENGTH"
        links.new(joined.outputs[0], length.inputs[0])
        ramp = nodes.new("ShaderNodeMapRange")
        ramp.inputs["From Min"].default_value = 0.31
        ramp.inputs["From Max"].default_value = 0.27
        links.new(length.outputs["Value"], ramp.inputs["Value"])
        return ramp.outputs["Result"]

    def facing(axis):
        """1 on faces whose normal points along `axis` (|n.axis| > 0.8)."""
        absolute = nodes.new("ShaderNodeMath")
        absolute.operation = "ABSOLUTE"
        links.new(normal.outputs[axis], absolute.inputs[0])
        greater = nodes.new("ShaderNodeMath")
        greater.operation = "GREATER_THAN"
        links.new(absolute.outputs[0], greater.inputs[0])
        greater.inputs[1].default_value = 0.8
        return greater.outputs[0]

    height = None
    for plane, axis in ((("X", "Y"), "Z"), (("X", "Z"), "Y"), (("Y", "Z"), "X")):
        weighted = nodes.new("ShaderNodeMath")
        weighted.operation = "MULTIPLY"
        links.new(disc(*plane), weighted.inputs[0])
        links.new(facing(axis), weighted.inputs[1])
        if height is None:
            height = weighted.outputs[0]
        else:
            add = nodes.new("ShaderNodeMath")
            add.operation = "ADD"
            links.new(height, add.inputs[0])
            links.new(weighted.outputs[0], add.inputs[1])
            height = add.outputs[0]
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.7
    bump.inputs["Distance"].default_value = 0.12 * stud
    links.new(height, bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    links.new(bsdf.outputs[0], out.inputs["Surface"])
    _STUD_MATERIALS[key] = mat
    return mat


def studify(objects, stud=2.0, alpha=1.0, tint=None):
    """Swaps every material of `objects` for the stud material of its base colour."""
    for obj in objects:
        for index, material in enumerate(obj.data.materials):
            color, emission = base_color(material)
            if tint is not None:
                color = tuple(int(c * 0.35 + t * 0.65) for c, t in zip(color, tint))
            obj.data.materials[index] = stud_material(color, emission, stud, alpha)
    return objects


def place(world_dir, name, location=(0, 0, 0), rot_z=0.0, scale=1.0, stud=2.0, alpha=1.0, tint=None, rot=(0, 0)):
    """Imports a world model at a location / yaw / scale with stud materials."""
    matrix = (
        Matrix.Translation(Vector(location))
        @ Matrix.Rotation(math.radians(rot_z), 4, "Z")
        @ Matrix.Rotation(math.radians(rot[0]), 4, "X")
        @ Matrix.Rotation(math.radians(rot[1]), 4, "Y")
        @ Matrix.Scale(scale, 4)
    )
    return studify(import_glb(os.path.join(world_dir, name + ".glb"), matrix), stud, alpha, tint)


def ground(size, color=(98, 204, 70), stud=2.0, location=(0, 0, 0)):
    """A big stud baseplate."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for vert in bm.verts:
        vert.co = Vector((vert.co.x * size[0], vert.co.y * size[1], vert.co.z * 1.0 - 0.5)) + Vector(location)
    mesh = bpy.data.meshes.new("Ground")
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Ground", mesh)
    obj.data.materials.append(stud_material(color, 0.0, stud))
    bpy.context.scene.collection.objects.link(obj)
    return obj


def lit_scene(width=1920, height=1080):
    """A bright daytime scene: sky-blue world, warm sun with soft shadows, filmic-free toy colour."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _STUD_MATERIALS.clear()
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = width * 2
    scene.render.resolution_y = height * 2
    scene.render.resolution_percentage = 25 if PREVIEW else 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.eevee.taa_render_samples = 8 if PREVIEW else 48
    # Standard view: saturated toy colours (AgX desaturated the scene into a foggy look).
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = -0.15
    world = bpy.data.worlds.new("Sky")
    scene.world = world
    if bpy.app.version < (5, 0, 0):
        world.use_nodes = True
    nodes, links = world.node_tree.nodes, world.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputWorld")
    background = nodes.new("ShaderNodeBackground")
    # Sky gradient by view direction: horizon pale, zenith deep sky blue.
    coords = nodes.new("ShaderNodeTexCoord")
    split = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coords.outputs["Generated"], split.inputs[0])
    ramp = nodes.new("ShaderNodeValToRGB")
    # World "Generated" = view direction: z 0 at the horizon, 1 at the zenith.
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.62, 0.84, 1.0, 1)
    ramp.color_ramp.elements[1].position = 0.55
    ramp.color_ramp.elements[1].color = (0.18, 0.5, 0.98, 1)
    links.new(split.outputs["Z"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], background.inputs["Color"])
    background.inputs["Strength"].default_value = 0.65
    links.new(background.outputs[0], out.inputs["Surface"])
    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun_data.energy = 3.6
    sun_data.angle = math.radians(4)
    sun_data.color = (1.0, 0.97, 0.9)
    sun = bpy.data.objects.new("Sun", sun_data)
    sun.rotation_euler = Vector((0.45, 0.6, -0.65)).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(sun)
    return scene


def perspective_camera(scene, location, target, lens=35):
    """A perspective camera at `location` aimed at `target`."""
    data = bpy.data.cameras.new("Camera")
    data.lens = lens
    data.clip_start = 0.5
    data.clip_end = 5000
    camera = bpy.data.objects.new("Camera", data)
    camera.location = Vector(location)
    camera.rotation_euler = (Vector(target) - Vector(location)).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(camera)
    scene.camera = camera
    return camera


def clouds(world_dir, spots):
    """Toy clouds (Scenery_CloudBig / Scenery_Cloud) at (x, y, z, scale, big)."""
    for x, y, z, scale, big in spots:
        place(world_dir, "Scenery_CloudBig" if big else "Scenery_Cloud", (x, y, z), 0, scale)


def garage(world_dir, location, rot_z=0.0, scale=1.0, roof=False):
    """
    B4's Area 1 garage, assembled (its pieces share one frame) + workbench, reactor, Uncle Atom.
    Cutaway by default (no roof) so the camera sees inside, like a dollhouse.
    """
    pieces = ["Garage_Floor", "Garage_WallBack", "Garage_WallSide", "Workbench", "MiniReactor", "A1_UncleAtom", "ToolWall", "GlowLamp"]
    if roof:
        pieces.append("Garage_Roof")
    for piece in pieces:
        offset = {"Workbench": (-4, -6, 0.7), "MiniReactor": (-4, -6, 4.9), "A1_UncleAtom": (4, 2, 0.7), "ToolWall": (-6, -11, 0.7), "GlowLamp": (7, -8, 0.7)}.get(piece, (0, 0, 0))
        local = Matrix.Rotation(math.radians(rot_z), 4, "Z") @ Vector(offset) * scale
        place(world_dir, piece, Vector(location) + local, rot_z, scale)


def render_hub(out_dir, world_dir):
    """Hub key art (loading-screen backdrop): plaza + monument ringed by 8 plot gates with builds."""
    scene = lit_scene()
    ground((1600, 1600), stud=4.0)
    place(world_dir, "Hub_CenterPlaza", (0, 0, 0.6), 0, 1.0, stud=4.0)
    place(world_dir, "Hub_Monument", (0, 0, 0.6), 0, 0.9, stud=4.0)
    builds = (
        ("Garage", None), ("A2_StandCounter", "A2_Awning"), ("A3_HQ", None), ("A5_LabShell", None),
        ("A6_RocketLine", None), ("A7_SiloBase", "A7_SiloNuke_Red"), ("A9_LaunchTower", "A9_Rocket"), ("A10_ReactorDome", "A10_CoolingTower"),
    )
    for index in range(8):
        angle = math.radians(22.5 + index * 45)
        direction = Vector((math.cos(angle), math.sin(angle), 0))
        yaw = math.degrees(angle) - 90
        gate = direction * 104
        place(world_dir, "Hub_PlotGate", (gate.x, gate.y, 0.6), yaw, 1.0, stud=4.0)
        place(world_dir, f"Hub_Digit{index + 1}", (gate.x, gate.y, 34), yaw, 1.0, stud=4.0)
        plot = direction * 190
        ground((120, 120), (110, 214, 84), 4.0, (plot.x, plot.y, 1.0))
        first, second = builds[index]
        if first == "Garage":
            garage(world_dir, (plot.x, plot.y, 1.1), yaw + 180, 1.4)
        else:
            place(world_dir, first, (plot.x, plot.y, 1.1), yaw + 180, 1.2, stud=4.0)
            if second:
                place(world_dir, second, (plot.x + direction.y * 34, plot.y - direction.x * 34, 1.1), yaw, 1.0, stud=4.0)
        tree = direction * 140 + Vector((-direction.y, direction.x, 0)) * 40
        place(world_dir, "Hub_Tree", (tree.x, tree.y, 0.6), index * 40, 1.2, stud=4.0)
    for name, offset in (("Hub_LuckyWheelStage", (46, -46)), ("Hub_EggStand", (-50, -40)), ("Hub_Leaderboard", (-46, 48)), ("Hub_SpawnPad", (40, 44))):
        place(world_dir, name, (offset[0], offset[1], 0.6), 45, 0.9, stud=4.0)
    clouds(world_dir, ((-260, 330, 160, 4.0, True), (300, 300, 190, 3.5, True), (40, 420, 220, 3.0, False)))
    perspective_camera(scene, (0, -350, 250), (0, 24, 0), lens=28)
    scene.render.filepath = os.path.join(out_dir, "Hub.png")
    bpy.ops.render.render(write_still=True)


RENDERS = {
    "Logo": lambda out, font, world: render_logo(out, font, world),
    "LogoText": lambda out, font, world: render_logo(out, font, world, with_nukey=False),
    "Nukey": lambda out, font, world: render_nukey(out, world),
    "Hub": lambda out, font, world: render_hub(out, world),
}


def main():
    """Entry: `-- <out_dir> <font.ttf> <world_dir> [Name ...] [--preview]` (names validated)."""
    argv = [a for a in (sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []) if a != "--preview"]
    if len(argv) < 3:
        raise SystemExit("usage: ... render_brand.py -- <out_dir> <font.ttf> <world_dir> [Name ...] [--preview]")
    out_dir, font, world = (os.path.abspath(a) for a in argv[:3])
    names = argv[3:] or list(RENDERS)
    for name in names:
        if name not in RENDERS:
            raise SystemExit(f"unknown render {name!r}; expected one of {sorted(RENDERS)}")
    os.makedirs(out_dir, exist_ok=True)
    for name in names:
        RENDERS[name](out_dir, font, world)
        print(f"RENDERED {name}")


if __name__ == "__main__":
    main()
