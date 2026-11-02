#!/usr/bin/env python3
"""
upload_world_studs.py — upload the world stud texture set (colour/normal/roughness) via Open Cloud.

Pipeline position:
    tools/ui/build_world_studs.py  ->  assets/world/studs/*.png + texture.json
    THIS SCRIPT                    ->  assets/world/studs/upload-receipts.json (Image asset ids)
                                   ->  the generated block of src/shared/Config/WorldMaterialConfig.luau
                                       (Images + Variants)
                                   ->  src/server/World/StudMaterialVariants.model.json (the
                                       MaterialVariant instances WorldMaterials clones into
                                       MaterialService; their map properties are PluginSecurity,
                                       so they cannot be set by game scripts at runtime)
    VARIANTS below is the single source of truth for variant names + stud density.

Safety (see tools/blender/snkit/cloud.py):
    * Every PNG is validated (signature, IHDR size, bounded bytes, sha256 == texture.json) BEFORE the
      key is read. Receipts are bound to the exact hash + creator, so reruns never re-upload.
    * Journal written before each POST; an ambiguous POST is never retried automatically.

Usage:
    python3 tools/ui/upload_world_studs.py --user-id 1586034782 [--dry-run] [--abandon color]
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/blender"))

from snkit import cloud  # noqa: E402  (path set above; snkit.cloud is pure Python)

DIRECTORY = ROOT / "assets/world/studs"
CONFIG = ROOT / "src/shared/Config/WorldMaterialConfig.luau"
VARIANT_MODEL = ROOT / "src/server/World/StudMaterialVariants.model.json"
# (config key, MaterialVariant name, StudsPerTile). The texture tile holds 2 x 2 stud cells, so
# StudsPerTile 2 = one stud cell per world stud (the references' density).
VARIANTS = (
    ("Studs", "SNStuds", 2.0),
    ("StudsSmall", "SNStudsSmall", 1.0),
    ("StudsLarge", "SNStudsLarge", 4.0),
)
KINDS = ("color", "normal", "roughness")
UPLOAD_KEYS = {"color": "StudsColor", "normal": "StudsNormal", "roughness": "StudsRoughness"}


def validate() -> dict:
    """Bind each PNG to texture.json; return {kind: {"path", "data", "hash"}} or raise UploadError."""
    contract = cloud.read_json(DIRECTORY / "texture.json")
    size = contract.get("width")
    if size not in (256, 512, 1024) or contract.get("height") != size:
        raise cloud.UploadError("texture.json has an unsupported size.")
    result = {}
    for kind in KINDS:
        meta = (contract.get("files") or {}).get(kind) or {}
        path = DIRECTORY / str(meta.get("file", ""))
        if path.parent.resolve() != DIRECTORY.resolve():
            raise cloud.UploadError("Texture paths must stay inside assets/world/studs.")
        data, digest = cloud.sha256_file(path, max_bytes=4_194_304)
        if (
            not data.startswith(b"\x89PNG\r\n\x1a\n")
            or struct.unpack(">II", data[16:24]) != (size, size)
            or digest != meta.get("sha256")
        ):
            raise cloud.UploadError(f"{path.name}: PNG header, size or hash does not match texture.json.")
        result[kind] = {"path": path, "data": data, "hash": digest}
    return result


def write_config_ids(ids: dict) -> None:
    """
    Rewrite only the generated block in WorldMaterialConfig.luau (between the BEGIN/END markers),
    so hand-written tables in the rest of the file are never touched.
    """
    variants = "".join(
        f'\t{key} = {{ name = "{name}", studsPerTile = {spt:g} }},\n' for key, name, spt in VARIANTS
    )
    block = (
        "-- BEGIN GENERATED STUD IMAGES (tools/ui/upload_world_studs.py)\n"
        "local IMAGES = {\n"
        f"\tColor = {ids['color']},\n"
        f"\tNormal = {ids['normal']},\n"
        f"\tRoughness = {ids['roughness']},\n"
        "}\n"
        "local VARIANTS: { [string]: VariantSpec } = {\n" + variants + "}\n"
        "-- END GENERATED STUD IMAGES"
    )
    text = CONFIG.read_text(encoding="utf-8")
    pattern = re.compile(r"-- BEGIN GENERATED STUD IMAGES.*?-- END GENERATED STUD IMAGES", re.S)
    if not pattern.search(text):
        raise cloud.UploadError("WorldMaterialConfig.luau lost its generated-images markers.")
    CONFIG.write_text(pattern.sub(lambda _m: block, text), encoding="utf-8")


def write_variant_model(ids: dict) -> None:
    """Write the Rojo model.json holding one MaterialVariant per VARIANTS row (same three maps)."""
    children = [
        {
            "name": name,
            "className": "MaterialVariant",
            "properties": {
                "BaseMaterial": "Plastic",
                "ColorMap": f"rbxassetid://{ids['color']}",
                "NormalMap": f"rbxassetid://{ids['normal']}",
                "RoughnessMap": f"rbxassetid://{ids['roughness']}",
                "StudsPerTile": spt,
            },
        }
        for _key, name, spt in VARIANTS
    ]
    model = {"className": "Folder", "children": children}
    VARIANT_MODEL.write_text(json.dumps(model, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    """Validate offline, then upload each missing image once and record its id."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--abandon", choices=KINDS, nargs="*", default=[])
    args = parser.parse_args()
    if not cloud.ASSET_ID.fullmatch(args.user_id):
        parser.error("--user-id must be a positive integer")
    sources = validate()
    if args.dry_run:
        print(f"[studs-upload] validated {len(sources)} PNGs; dry run made no network requests")
        return 0
    creator = {"userId": args.user_id}
    client = cloud.Client(cloud.read_key(), timeout=60)
    ids = {}
    with cloud.exclusive(DIRECTORY):
        for kind in KINDS:
            source = sources[kind]
            identity = {"hash": source["hash"], "creator": creator, "assetType": "Image"}
            key = UPLOAD_KEYS[kind]
            receipt = cloud.journaled_upload(
                DIRECTORY,
                key,
                identity,
                lambda s=source, k=key: client.create_asset(
                    "Image",
                    f"SellNukes {k}",
                    "Original SellNukes stud material map (generated by build_world_studs.py).",
                    creator,
                    f"{k}.png",
                    "image/png",
                    s["data"],
                ),
                client,
                abandon=kind in args.abandon,
            )
            ids[kind] = receipt["assetId"]
            print(f"[studs-upload] {kind}: image {receipt['assetId']} (moderation {receipt['moderation']})")
    write_config_ids(ids)
    write_variant_model(ids)
    print("[studs-upload] WorldMaterialConfig + StudMaterialVariants.model.json regenerated")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except cloud.UploadError as error:
        print(f"[studs-upload] {error}", file=sys.stderr)
        sys.exit(1)
