"""
snkit.export — turn a snkit Model into Blender objects, export FBX/GLB, render previews, and
describe every piece for the manifest (size, offset, colour, material, triangles, sha256).

realize(model) per piece:
    1. recalc outward normals
    2. world-scale CUBE-PROJECTED UVs: each face picks its dominant axis and maps the other two
       Roblox coordinates to UV at UV_STUDS studs per UV unit (scaled per stud material).
       Roblox's MaterialVariant projection on MeshParts does NOT read these UVs (experiment in
       docs/world-art.md), but they keep tangent export valid, make the Blender previews show
       the true stud size, and let a SurfaceAppearance fallback work if ever needed.
       UV frames are right-handed per face (tangent x bitangent = normal).
    3. sharp edges where faces meet at > SHARP_ANGLE (crisp toy chamfers, smooth cylinders)
    4. triangulate (exact triangle counts + tangents are always exportable)

export(): binary FBX (axis forward -Z, up Y, tangent space ON, normals only) + GLB.
render_previews(): Blender Workbench, front + 3/4 iso, stud texture tinted per piece colour so the
previews look like the game (assets/blender/previews/<Key>_front.jpg / _iso.jpg).
"""

from __future__ import annotations

import hashlib
import math
import os
import struct

import bmesh
import bpy
from mathutils import Vector

from .core import br

UV_STUDS = 2.0  # studs per UV unit; one UV unit = one 512 px texture tile = 2 x 2 studs
SHARP_ANGLE = math.radians(35.0)
STUD_TEXTURE = None  # set by generate_world.py: absolute path of assets/world/studs/studs_color.png
_tinted_cache: dict = {}


def reset_scene():
    """Empty factory scene (no default cube/light/camera); add-ons such as FBX stay available."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _tinted_cache.clear()


def _cube_uv(bm: bmesh.types.BMesh, studs_per_uv: float):
    """Assign right-handed, world-scale cube-projected UVs to every loop (see module doc)."""
    uv_layer = bm.loops.layers.uv.verify()
    for face in bm.faces:
        n = br(face.normal)  # Roblox-space normal
        ax, ay, az = abs(n[0]), abs(n[1]), abs(n[2])
        for loop in face.loops:
            x, y, z = br(loop.vert.co)
            if ay >= ax and ay >= az:
                # Top: u = +X, v = -Z.  Bottom: u = +X, v = +Z.
                u, v = (x, -z) if n[1] >= 0 else (x, z)
            elif ax >= az:
                # +X face: u = -Z, v = +Y.  -X face: u = +Z, v = +Y.
                u, v = (-z, y) if n[0] >= 0 else (z, y)
            else:
                # +Z face: u = +X, v = +Y.  -Z face: u = -X, v = +Y.
                u, v = (x, y) if n[2] >= 0 else (-x, y)
            loop[uv_layer].uv = (u / studs_per_uv, v / studs_per_uv)


def _mark_sharp(bm: bmesh.types.BMesh):
    """Smooth-shade faces, but keep edges sharper than SHARP_ANGLE crisp."""
    for face in bm.faces:
        face.smooth = True
    for edge in bm.edges:
        if len(edge.link_faces) != 2:
            edge.smooth = False
            continue
        try:
            angle = edge.calc_face_angle()
        except ValueError:
            angle = math.pi
        edge.smooth = angle <= SHARP_ANGLE


def piece_hash(piece, mesh) -> str:
    """
    sha256 over everything that changes what Roblox renders for this piece: name, colour,
    material, transparency, vertex positions (1e-4 stud), triangles and UVs (1e-4).
    """
    h = hashlib.sha256()
    h.update(f"{piece.name}|{piece.color}|{piece.material}|{piece.transparency:.3f}|{piece.tinted}".encode())
    for v in mesh.vertices:
        h.update(struct.pack("<3i", *(round(c * 10000) for c in v.co)))
    uv = mesh.uv_layers.active.data if mesh.uv_layers.active else None
    for poly in mesh.polygons:
        h.update(struct.pack(f"<{len(poly.vertices)}I", *poly.vertices))
        if uv is not None:
            for li in poly.loop_indices:
                h.update(struct.pack("<2i", round(uv[li].uv[0] * 10000), round(uv[li].uv[1] * 10000)))
    return h.hexdigest()


def _flat_image(name: str, rgba) -> bpy.types.Image:
    """4x4 solid-colour image (preview material for non-stud pieces)."""
    img = bpy.data.images.new(name, 4, 4, alpha=True)
    img.pixels.foreach_set([*rgba] * 16)
    return img


def _tinted_studs(rgb) -> bpy.types.Image | None:
    """Stud colour map multiplied by the piece colour (cached per colour) for Workbench previews."""
    if STUD_TEXTURE is None or not os.path.exists(STUD_TEXTURE):
        return None
    key = tuple(rgb)
    if key in _tinted_cache:
        return _tinted_cache[key]
    base = bpy.data.images.get("_studs_base") or bpy.data.images.load(STUD_TEXTURE)
    base.name = "_studs_base"
    w, h = base.size
    import numpy as np  # bundled with Blender

    px = np.empty(w * h * 4, dtype=np.float32)
    base.pixels.foreach_get(px)
    px = px.reshape(-1, 4)
    # For 8-bit images .pixels holds the file's sRGB-encoded values / 255, so multiplying by the
    # sRGB piece colour approximates Roblox's Color x ColorMap tint closely enough for previews.
    tint = np.array([c / 255.0 for c in rgb] + [1.0], dtype=np.float32)
    out = (px * tint).reshape(-1)
    img = bpy.data.images.new(f"_studs_{key}", w, h, alpha=True)
    img.pixels.foreach_set(out)
    _tinted_cache[key] = img
    return img


def make_material(piece) -> bpy.types.Material:
    """
    Preview/export material. Base colour = piece colour (Roblox overrides it at runtime anyway);
    an Image Texture node with tinted studs is added for stud pieces so Workbench TEXTURE previews
    show the real stud look. Glass gets alpha; Neon gets emission.
    """
    mat = bpy.data.materials.new(piece.name)
    rgb = tuple(c / 255 for c in piece.color)
    alpha = 1.0 - piece.transparency
    mat.diffuse_color = (*rgb, alpha)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes.get("Principled BSDF")
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
        bsdf.inputs["Alpha"].default_value = alpha
        if piece.material == "Neon":
            emission = bsdf.inputs.get("Emission Color") or bsdf.inputs.get("Emission")
            if emission is not None:
                emission.default_value = (*rgb, 1.0)
    if alpha < 1.0:
        for attr, value in (("surface_render_method", "BLENDED"), ("blend_method", "BLEND")):
            if hasattr(mat, attr):
                try:
                    setattr(mat, attr, value)
                except (TypeError, ValueError):
                    pass
    image = None
    if piece.material in ("Studs", "StudsSmall", "StudsLarge"):
        image = _tinted_studs(piece.color)
    if image is None:
        image = _flat_image(f"_flat_{piece.name}", (*rgb, alpha))
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = image
    nodes.active = tex
    return mat


def realize(model) -> list:
    """Build Blender objects for every non-empty piece. Returns [(piece, object)]."""
    objects = []
    for piece in model.pieces.values():
        bm = piece.bm
        if len(bm.faces) == 0:
            continue
        bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
        bm.normal_update()
        _cube_uv(bm, UV_STUDS * {"StudsSmall": 0.5, "StudsLarge": 2.0}.get(piece.material, 1.0))
        _mark_sharp(bm)
        bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
        mesh = bpy.data.meshes.new(piece.name)
        bm.to_mesh(mesh)
        bm.free()
        obj = bpy.data.objects.new(piece.name, mesh)
        obj.data.materials.append(make_material(piece))
        bpy.context.scene.collection.objects.link(obj)
        objects.append((piece, obj))
    return objects


def bbox_roblox(obj):
    """(size, centre) of an object's vertices in Roblox axes, rounded to 1e-3 studs."""
    pts = [br(v.co) for v in obj.data.vertices]
    lo = [min(p[i] for p in pts) for i in range(3)]
    hi = [max(p[i] for p in pts) for i in range(3)]
    size = [round(max(hi[i] - lo[i], 0.05), 3) for i in range(3)]
    center = [round((hi[i] + lo[i]) / 2, 3) for i in range(3)]
    return size, center


def export(objects, out_dir: str, key: str):
    """Binary FBX for Roblox (tangents on) + GLB for any other viewer."""
    bpy.ops.object.select_all(action="DESELECT")
    for _, obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0][1]
    bpy.ops.export_scene.fbx(
        filepath=os.path.join(out_dir, f"{key}.fbx"),
        use_selection=True,
        object_types={"MESH"},
        axis_forward="-Z",
        axis_up="Y",
        bake_space_transform=True,
        mesh_smooth_type="OFF",
        use_tspace=True,
        add_leaf_bones=False,
        bake_anim=False,
        path_mode="STRIP",
        embed_textures=False,
    )
    bpy.ops.export_scene.gltf(
        filepath=os.path.join(out_dir, f"{key}.glb"),
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_apply=True,
    )


def render_previews(objects, preview_dir: str, key: str):
    """
    Workbench renders: <key>_front.jpg (straight on from Roblox front, slightly above) and
    <key>_iso.jpg (front-right-above 3/4). Stud pieces show the tinted stud texture.
    """
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 720
    scene.render.film_transparent = False
    # JPEG keeps 40-odd previews per area around 2 MB in git instead of ~25 MB of PNG.
    scene.render.image_settings.file_format = "JPEG"
    scene.render.image_settings.quality = 88
    shading = scene.display.shading
    shading.light = "STUDIO"
    shading.color_type = "TEXTURE"
    shading.show_shadows = True
    shading.shadow_intensity = 0.35
    shading.show_cavity = True
    shading.cavity_type = "WORLD"
    shading.show_object_outline = False
    shading.background_type = "VIEWPORT"
    shading.background_color = (0.62, 0.78, 0.95)
    scene.display.light_direction = (0.45, -0.35, 0.82)
    # "Standard" shows the authored colours 1:1 (AgX/Filmic would desaturate the candy palette).
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for _, obj in objects:
        for v in obj.data.vertices:
            lo = Vector((min(lo.x, v.co.x), min(lo.y, v.co.y), min(lo.z, v.co.z)))
            hi = Vector((max(hi.x, v.co.x), max(hi.y, v.co.y), max(hi.z, v.co.z)))
    centre = (lo + hi) / 2
    radius = max((hi - lo).length / 2, 0.5)
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.lens = 50
    cam_data.clip_start = 0.05
    cam_data.clip_end = 10000
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    # Blender-space directions: Roblox front (-Z) is Blender +Y; up is Blender +Z.
    views = {"front": (0.0, 1.0, 0.32), "iso": (0.85, 1.15, 0.8)}
    # Fit the bounding sphere inside the narrower (vertical) field of view with ~10 % margin.
    vertical_fov = 2 * math.atan((cam_data.sensor_width / 2) * (720 / 900) / cam_data.lens)
    distance = radius / math.sin(vertical_fov / 2) * 1.08
    for view, direction in views.items():
        d = Vector(direction).normalized()
        cam.location = centre + d * distance
        cam.rotation_euler = (centre - cam.location).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(preview_dir, f"{key}_{view}.jpg")
        bpy.ops.render.render(write_still=True)
