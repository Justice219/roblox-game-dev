"""
generate_world.py — build every SellNukes world model in Blender (headless), export, preview, manifest.

Pipeline (docs/world-art.md has the full recipe):
    1. THIS SCRIPT     Blender builders -> assets/blender/world/<Key>.fbx (+ .glb)
                       previews        -> assets/blender/previews/<Key>_front.jpg, <Key>_iso.jpg
                       manifest        -> assets/blender/world/manifest.json
    2. upload_meshes.py   FBX -> Open Cloud Model -> MeshIds (journal + receipts, resumable)
    3. sync_meshes.py     manifest + receipts -> src/shared/Config/MeshAssets.luau
    4. MeshLibrary.spawn  (server) clones cached MeshPart templates, stud material applied

Builders live in tools/blender/models/*.py and are AUTO-DISCOVERED (every module file except
__init__.py): each module exports BUILDERS = {key: fn} where fn() -> snkit.core.Model, so parallel
art builders each add their own models/<name>.py without editing a shared registry. Duplicate keys
across modules fail the build. A Model carries a triangle `budget`; the build FAILS if any model
goes over it, so the world stays cheap (hundreds of meshes are on screen at once).

Concurrency: several builders may run `generate_world.py --only <their keys>` at once. Each run
builds without any lock, then merges ONLY its own keys into manifest.json under the exclusive
`.sn-manifest.lock` (blocking, re-reading the manifest inside the lock), so no run can drop another
run's entries. Exports and previews are per-key files, so they never collide.

Manifest entry (per model key):
    {"pivot": str, "budget": int, "triangles": int, "fbxSha256": str,
     "pieces": [{"name", "size":[x,y,z], "offset":[x,y,z], "color":[r,g,b], "material",
                 "tinted", "transparency", "triangles", "hash"}]}
    size/offset are the piece's bounding box in Roblox axes relative to the model pivot.

Usage:
    /opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- \
        [--only BuyPad,PocketNuke] [--out assets/blender/world] [--previews assets/blender/previews] \
        [--no-previews]
"""

from __future__ import annotations

import hashlib
import importlib
import os
import re
import sys
import time
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from snkit import cloud  # noqa: E402  (pure Python: locks + atomic JSON)
from snkit import export as snexport  # noqa: E402  (needs HERE on sys.path inside Blender)

MODELS_DIR = os.path.join(HERE, "models")
TEST_MODULE = "models.tests"  # experiment-only models: built only when named with --only
NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,60}\Z")
MAX_PIECES = 24  # draw calls per model; above this, merge same-colour details
MAX_PIECE_TRIANGLES = 10_000  # Roblox MeshPart hard limit is 20k; stay well under


def parse_args():
    """Parse the args after Blender's `--` separator."""
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    opts = {
        "only": None,
        "out": os.path.join(ROOT, "assets/blender/world"),
        "previews": os.path.join(ROOT, "assets/blender/previews"),
        "render": True,
    }
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--only":
            opts["only"] = [k for k in argv[i + 1].split(",") if k]
            i += 2
        elif arg == "--out":
            opts["out"] = os.path.abspath(argv[i + 1])
            i += 2
        elif arg == "--previews":
            opts["previews"] = os.path.abspath(argv[i + 1])
            i += 2
        elif arg == "--no-previews":
            opts["render"] = False
            i += 1
        else:
            raise SystemExit(f"unknown argument {arg}")
    return opts


def discover_modules():
    """Every tools/blender/models/<name>.py except __init__, sorted for a stable build order."""
    names = []
    for filename in sorted(os.listdir(MODELS_DIR)):
        stem, ext = os.path.splitext(filename)
        if ext == ".py" and stem != "__init__" and re.fullmatch(r"[a-z][a-z0-9_]*", stem):
            names.append(f"models.{stem}")
    return names


def collect_builders(only):
    """Import every model module; test-only builders (models.tests) run only when named."""
    builders = {}
    owners = {}
    for name in discover_modules():
        module = importlib.import_module(name)
        table = getattr(module, "BUILDERS", None)
        if not isinstance(table, dict):
            raise SystemExit(f"{name} has no BUILDERS dict")
        for key, fn in table.items():
            if key in owners:
                raise SystemExit(f"duplicate model key {key} in {name} and {owners[key]}")
            owners[key] = name
            if name == TEST_MODULE and (only is None or key not in only):
                continue
            builders[key] = fn
    if only is not None:
        missing = [k for k in only if k not in builders]
        if missing:
            raise SystemExit(f"unknown model keys: {', '.join(missing)}")
        builders = {k: v for k, v in builders.items() if k in only}
    return builders


def merge_manifest(out_dir, entries):
    """
    Merge this run's entries into manifest.json under the exclusive manifest lock: re-read the
    file INSIDE the lock, replace only our keys, write atomically (fsync + rename). Other builders'
    keys are preserved no matter how runs interleave.
    """
    directory = Path(out_dir)
    path = directory / "manifest.json"
    with cloud.exclusive(directory, cloud.MANIFEST_LOCK):
        manifest = cloud.read_json(path, {}) if path.exists() else {}
        manifest.update(entries)
        cloud.atomic_json(path, manifest)
    return str(path), len(manifest)


def main():
    opts = parse_args()
    os.makedirs(opts["out"], exist_ok=True)
    os.makedirs(opts["previews"], exist_ok=True)
    snexport.STUD_TEXTURE = os.path.join(ROOT, "assets/world/studs/studs_color.png")
    entries = {}
    builders = collect_builders(opts["only"])
    failures = []
    failed_keys = set()  # over-budget models never reach the manifest (so they cannot be uploaded)
    started = time.time()
    for key, builder in builders.items():
        snexport.reset_scene()
        model = builder()
        if model.key != key or not NAME.fullmatch(key):
            raise SystemExit(f"builder for {key} returned model {model.key}")
        objects = snexport.realize(model)
        if not objects:
            raise SystemExit(f"{key}: no geometry")
        if len(objects) > MAX_PIECES:
            failures.append(f"{key}: {len(objects)} pieces > {MAX_PIECES}")
            failed_keys.add(key)
        pieces = []
        total = 0
        for piece, obj in objects:
            if not NAME.fullmatch(piece.name):
                raise SystemExit(f"{key}: invalid piece name {piece.name!r}")
            size, center = snexport.bbox_roblox(obj)
            tris = len(obj.data.polygons)  # triangulated in realize()
            total += tris
            if tris > MAX_PIECE_TRIANGLES:
                failures.append(f"{key}.{piece.name}: {tris} triangles > {MAX_PIECE_TRIANGLES}")
                failed_keys.add(key)
            pieces.append(
                {
                    "name": piece.name,
                    "size": size,
                    "offset": center,
                    "color": list(piece.color),
                    "material": piece.material,
                    "tinted": piece.tinted,
                    "transparency": piece.transparency,
                    "triangles": tris,
                    "hash": snexport.piece_hash(piece, obj.data),
                }
            )
        if total > model.budget:
            failures.append(f"{key}: {total} triangles > budget {model.budget}")
            failed_keys.add(key)
        snexport.export(objects, opts["out"], key)
        with open(os.path.join(opts["out"], f"{key}.fbx"), "rb") as handle:
            fbx_hash = hashlib.sha256(handle.read()).hexdigest()
        entries[key] = {
            "pivot": model.pivot,
            "budget": model.budget,
            "triangles": total,
            "fbxSha256": fbx_hash,
            "pieces": sorted(pieces, key=lambda p: p["name"]),
        }
        if opts["render"]:
            snexport.render_previews(objects, opts["previews"], key)
        print(f"[world] {key}: {len(objects)} pieces, {total}/{model.budget} tris")
    good = {k: v for k, v in entries.items() if k not in failed_keys}
    manifest_path, total_models = merge_manifest(opts["out"], good)
    print(
        f"[world] manifest -> {manifest_path} ({len(builders)} built, {total_models} total, "
        f"{time.time() - started:.1f}s)"
    )
    if failures:
        for line in failures:
            print(f"[world] BUDGET FAIL {line}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
