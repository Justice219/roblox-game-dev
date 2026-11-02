"""
snkit — the SellNukes Blender kit (ported from RoBeasts tools/blender/generate_models.py).

Modules:
    snkit.core     Roblox<->Blender axes, Model/Piece containers, palette, material names.   (bpy)
    snkit.shapes   Low-level mesh primitives: box (bevel), bar, cylinder, ellipsoid, prism,
                   revolve, ring_tube, loft, polygon clipping.                                  (bpy)
    snkit.kit      Stud-friendly toy helpers: block, hazard_band, hazard_floor, pipe, tank,
                   truss/ladder, sign_frame, tyre_ring, nuke_body, tree, lamp.                 (bpy)
    snkit.export   realize (cube-projected world-scale UVs, sharp edges, triangulation),
                   per-piece sha256, FBX/GLB export, previews (front + 3/4 iso), manifest.     (bpy)
    snkit.cloud    Open Cloud transport + durable upload journal.                       (pure Python)

This __init__ deliberately imports nothing so `from snkit import cloud` works on the system
python3 (no bpy) for the uploaders.
"""
