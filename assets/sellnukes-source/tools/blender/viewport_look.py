"""
viewport_look.py — render models lit like a Roblox ViewportFrame (shop tiles) for colour review.

The pipeline preview (snkit.export.render_previews: Workbench STUDIO light, cavity, shadows) shows
authored colours at roughly half brightness, so saturated yellows / golds look olive or brown there.
A shop ViewportFrame is ambient-heavy, so in game a piece shows ~ colour x stud map (~0.9). This
renders FLAT colour x the real stud texture, with cavity shading to keep the form, on a dark
shop-panel background: use it to judge colour (owner R47 "washed out" / lead "muddy" passes).

Any builders module works (a repo model file or an older copy from `git show`), so a before / after
pair is two runs.

Usage:
    /opt/homebrew/bin/blender -b --python tools/blender/viewport_look.py -- OUT_DIR KEY1,KEY2 MODULE.py
Example:
    /opt/homebrew/bin/blender -b --python tools/blender/viewport_look.py -- /tmp/vp \
        Shop_OfflineMoon,Shop_TripleEgg tools/blender/models/shop_props.py
    -> /tmp/vp/Shop_OfflineMoon_iso.jpg, /tmp/vp/Shop_TripleEgg_iso.jpg (same iso angle as the previews)
"""

import importlib.util
import math
import os
import sys

import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools/blender"))
from snkit import export as snexport  # noqa: E402


def load_builders(module_path: str) -> dict:
    """Import a models file by path (repo file or a `git show` copy) and return its BUILDERS."""
    spec = importlib.util.spec_from_file_location("viewport_look_models", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.BUILDERS


def render(objects, path: str) -> None:
    """FLAT colour x stud texture + cavity, iso camera fitted to the model's bounding sphere."""
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x, scene.render.resolution_y = 900, 720
    scene.render.image_settings.file_format = "JPEG"
    shading = scene.display.shading
    shading.light = "FLAT"
    shading.color_type = "TEXTURE"
    shading.show_cavity = True
    shading.cavity_type = "BOTH"
    shading.cavity_ridge_factor = 0.6
    shading.cavity_valley_factor = 1.4
    shading.curvature_ridge_factor = 0.6
    shading.curvature_valley_factor = 1.4
    shading.show_shadows = False
    shading.background_type = "VIEWPORT"
    shading.background_color = (0.16, 0.17, 0.22)
    scene.view_settings.view_transform = "Standard"
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    for _, obj in objects:
        for v in obj.data.vertices:
            lo = Vector((min(lo.x, v.co.x), min(lo.y, v.co.y), min(lo.z, v.co.z)))
            hi = Vector((max(hi.x, v.co.x), max(hi.y, v.co.y), max(hi.z, v.co.z)))
    centre, radius = (lo + hi) / 2, max((hi - lo).length / 2, 0.5)
    cam_data = bpy.data.cameras.new("ViewportLookCam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("ViewportLookCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    fov = 2 * math.atan((cam_data.sensor_width / 2) * (720 / 900) / cam_data.lens)
    d = Vector((0.85, 1.15, 0.8)).normalized()  # same iso direction as render_previews
    cam.location = centre + d * (radius / math.sin(fov / 2) * 1.08)
    cam.rotation_euler = (centre - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main() -> None:
    out_dir, keys, module_path = sys.argv[sys.argv.index("--") + 1 :][:3]
    os.makedirs(out_dir, exist_ok=True)
    builders = load_builders(module_path)
    snexport.STUD_TEXTURE = os.path.join(ROOT, "assets/world/studs/studs_color.png")
    for key in keys.split(","):
        snexport.reset_scene()
        render(snexport.realize(builders[key]()), os.path.join(out_dir, f"{key}_iso.jpg"))


main()
