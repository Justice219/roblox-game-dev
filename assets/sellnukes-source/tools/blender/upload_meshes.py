#!/usr/bin/env python3
"""
upload_meshes.py — upload Blender world FBXs as Roblox Models (Open Cloud) and recover MeshIds.

Pipeline position (docs/world-art.md):
    generate_world.py -> assets/blender/world/{<Key>.fbx, manifest.json}
    THIS SCRIPT       -> assets/blender/world/upload-receipts.json   (model asset id per key)
                      -> assets/blender/world/mesh-ids.json          (MeshId per piece, hash-bound)
    sync_meshes.py    -> src/shared/Config/MeshAssets.luau

Concurrency: each model is handled inside its own turn of the exclusive `.sn-upload.lock`
(blocking wait, up to 30 min), and journal / receipts / mesh-ids.json are re-read inside the lock and
only this key is replaced, so parallel builders running `--only <their keys>` never clobber each
other.

Idempotent + resumable:
    * Upload identity = (contentHash, creator). contentHash = sha256 over the model's sorted piece
      hashes (geometry, UVs, colour, material), NOT the FBX bytes (Blender stamps FBX files with a
      time, so bytes change on every build even when nothing visible did). Unchanged models are
      never uploaded twice; changed models upload a new asset and keep the old receipt in _history.
    * The FBX on disk must match manifest fbxSha256 (binds the file to the manifest build).
    * Journal written before every POST; ambiguous POSTs are never retried (--abandon KEY after
      checking Creator Dashboard). Extraction is re-run only for keys whose mesh ids are missing or
      whose contentHash changed.

MeshId recovery:
    Open Cloud asset-delivery download of the owned model (CDN hop without credentials), then
    `lune run tools/blender/extract_meshes.luau` decodes it as inert data. Names must equal the
    manifest's piece names exactly or nothing is recorded.

Usage:
    python3 tools/blender/upload_meshes.py --user-id 1586034782 [--only BuyPad PocketNuke] \
        [--dry-run] [--abandon KEY ...]
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

from snkit import cloud  # noqa: E402

DIRECTORY = ROOT / "assets/blender/world"
EXTRACTOR = HERE / "extract_meshes.luau"
MAX_PIECES = 24


def content_hash(pieces: list) -> str:
    """Stable identity of what Roblox will render for a model (independent of FBX timestamps)."""
    joined = "|".join(f"{p['name']}:{p['hash']}" for p in sorted(pieces, key=lambda p: p["name"]))
    return hashlib.sha256(joined.encode()).hexdigest()


def validate(manifest: dict, keys: list[str]) -> dict:
    """Bind each key's FBX bytes and piece identities before any credential or network use."""
    result = {}
    for key in keys:
        entry = manifest.get(key)
        if not isinstance(entry, dict) or not cloud.NAME.fullmatch(key):
            raise cloud.UploadError(f"{key}: not in manifest.json (run generate_world.py first).")
        pieces = entry.get("pieces")
        if not isinstance(pieces, list) or not 1 <= len(pieces) <= MAX_PIECES:
            raise cloud.UploadError(f"{key}: piece count outside 1..{MAX_PIECES}.")
        names = set()
        for piece in pieces:
            name, digest = piece.get("name"), piece.get("hash")
            if not isinstance(name, str) or not cloud.NAME.fullmatch(name) or name in names:
                raise cloud.UploadError(f"{key}: invalid or duplicate piece name.")
            if not isinstance(digest, str) or not cloud.HASH.fullmatch(digest):
                raise cloud.UploadError(f"{key}: invalid piece hash.")
            names.add(name)
        path = DIRECTORY / f"{key}.fbx"
        data, digest = cloud.sha256_file(path)
        if not data.startswith(b"Kaydara FBX Binary  \x00\x1a\x00"):
            raise cloud.UploadError(f"{key}: expected a Blender binary FBX.")
        if digest != entry.get("fbxSha256"):
            raise cloud.UploadError(f"{key}: FBX does not match manifest (rebuild with generate_world.py).")
        result[key] = {
            "data": data,
            "contentHash": content_hash(pieces),
            "pieceHashes": {p["name"]: p["hash"] for p in pieces},
        }
    return result


def extract(client: cloud.Client, key: str, model_id: int, source: dict) -> None:
    """
    Download the uploaded model, decode it with lune, verify names, record hash-bound ids.
    Caller holds the upload lock; mesh-ids.json is re-read here and only this key is replaced.
    """
    lune = shutil.which("lune") or str(Path.home() / ".aftman/bin/lune")
    data = client.download_model(model_id)
    with tempfile.TemporaryDirectory(prefix="sellnukes-mesh-extract-") as tmp:
        # Binary models start with "<roblox!", XML ones with "<roblox "; lune reads both.
        suffix = "rbxm" if data.startswith(b"<roblox!") else "rbxmx"
        model_path, out_path = Path(tmp) / f"model.{suffix}", Path(tmp) / "ids.json"
        model_path.write_bytes(data)
        result = subprocess.run(
            [lune, "run", str(EXTRACTOR), str(model_path), str(out_path)],
            capture_output=True,
            timeout=60,
            check=False,
        )
        if result.returncode != 0 or not out_path.is_file():
            raise cloud.UploadError(f"{key}: model decoding failed; no ids recorded.")
        meshes = cloud.read_json(out_path)
    expected = source["pieceHashes"]
    if set(meshes) != set(expected):
        missing = sorted(set(expected) - set(meshes))
        extra = sorted(set(meshes) - set(expected))
        raise cloud.UploadError(f"{key}: imported mesh names differ (missing {missing}, extra {extra}).")
    pieces = {}
    for name, digest in expected.items():
        asset_id = meshes[name].get("assetId")
        if type(asset_id) is not int or not 0 < asset_id < 2**53:
            raise cloud.UploadError(f"{key}: invalid MeshId for {name}.")
        pieces[name] = {"meshId": asset_id, "hash": digest}
    mesh_ids = cloud.read_json(DIRECTORY / "mesh-ids.json", {})
    mesh_ids[key] = {"contentHash": source["contentHash"], "modelId": model_id, "pieces": pieces}
    cloud.atomic_json(DIRECTORY / "mesh-ids.json", mesh_ids)
    print(f"[meshes] {key}: {len(pieces)} MeshIds recorded (model {model_id})", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--only", nargs="+")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--abandon", nargs="*", default=[])
    parser.add_argument("--include-tests", action="store_true", help="also upload test-only models (StudTest)")
    args = parser.parse_args()
    if not cloud.ASSET_ID.fullmatch(args.user_id):
        parser.error("--user-id must be a positive integer")
    manifest = cloud.read_json(DIRECTORY / "manifest.json")
    keys = args.only or sorted(k for k in manifest if args.include_tests or not k.startswith("StudTest"))
    sources = validate(manifest, keys)
    if args.dry_run:
        print(f"[meshes] validated {len(sources)} FBX models; dry run made no network requests")
        return 0
    creator = {"userId": args.user_id}
    client = cloud.Client(cloud.read_key(), timeout=60)
    for key in keys:
        # One lock turn per model: parallel builders interleave fairly instead of failing, and every
        # read-modify-write of the journal, receipts and mesh-ids.json happens inside the lock.
        with cloud.exclusive(DIRECTORY, cloud.UPLOAD_LOCK):
            source = sources[key]
            identity = {"contentHash": source["contentHash"], "creator": creator, "assetType": "Model"}
            receipt = cloud.journaled_upload(
                DIRECTORY,
                key,
                identity,
                lambda s=source, k=key: client.create_asset(
                    "Model",
                    f"SellNukes {k}"[:50],
                    "Original SellNukes Blender-authored world model.",
                    creator,
                    f"{k}.fbx",
                    "model/fbx",
                    s["data"],
                ),
                client,
                abandon=key in args.abandon,
            )
            print(f"[meshes] {key}: model {receipt['assetId']} ({receipt['moderation']})", flush=True)
            current = cloud.read_json(DIRECTORY / "mesh-ids.json", {}).get(key) or {}
            if current.get("contentHash") == source["contentHash"] and current.get("modelId") == receipt["assetId"]:
                continue
            extract(client, key, receipt["assetId"], source)
    print("[meshes] done; run python3 tools/blender/sync_meshes.py to regenerate MeshAssets.luau")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except cloud.UploadError as error:
        print(f"[meshes] {error}", file=sys.stderr)
        sys.exit(1)
