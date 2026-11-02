#!/usr/bin/env python3
"""
upload_sfx.py — upload SellNukes' synthesised SFX sets as Roblox Audio and regenerate the id table.

Sets (each a directory with <name>.mp3 + manifest.json from its generator):
    world  assets/audio/world-sfx   tools/audio/generate_world_sfx.py  (build-in / world FX)
    game   assets/audio/game-sfx    tools/audio/generate_game_sfx.py   (UI, cash, eggs, nukes, ...)
    voice  assets/audio/voice-sfx   picked ForgeGUI (ElevenLabs) announcer takes, owner R54
           (launch countdown + hit call-outs)
    forge  assets/audio/forge-sfx   picked ForgeGUI world sounds (vehicle horn / reverse beep, R56)
           (both manifests written by tools/audio/forge_manifest.py)

After uploading the requested set(s), the generated `SFX_IDS` block of
src/shared/Config/SoundAssets.luau is rewritten from the receipts of ALL sets, so one table holds
every synthesised SFX id (consumed by src/client/Audio/Sound.luau).

Safety (tools/blender/snkit/cloud.py): MP3s validated (regular file, size bound, frame sync / ID3,
sha256 == manifest) before the key is read; journal before POST; ambiguous POSTs never retried
(--abandon NAME after checking Creator Dashboard); waits for the set's upload lock; unchanged audio
never re-uploads (hash-bound receipts).

Usage:
    python3 tools/audio/upload_sfx.py --user-id 1586034782 [--set world game] [--dry-run] [--abandon ui_click]
    python3 tools/audio/upload_sfx.py --sync-only      # just regenerate SoundAssets from receipts
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/blender"))

from snkit import cloud  # noqa: E402

SETS = {
    "world": ROOT / "assets/audio/world-sfx",
    "game": ROOT / "assets/audio/game-sfx",
    "voice": ROOT / "assets/audio/voice-sfx",
    "forge": ROOT / "assets/audio/forge-sfx",
}
CONFIG = ROOT / "src/shared/Config/SoundAssets.luau"
NAME = re.compile(r"[a-z][a-z0-9_]{0,40}\Z")


def validate(directory: Path) -> dict:
    """Bind each MP3 of a set to its manifest; return {name: {"data", "hash"}}."""
    manifest = cloud.read_json(directory / "manifest.json")
    result = {}
    for name, meta in sorted(manifest.items()):
        if not NAME.fullmatch(name) or not isinstance(meta, dict):
            raise cloud.UploadError(f"{directory.name}: invalid sound name {name!r}.")
        path = directory / str(meta.get("file", ""))
        if path.parent.resolve() != directory.resolve() or path.suffix != ".mp3":
            raise cloud.UploadError(f"{name}: audio must be an .mp3 inside {directory.name}.")
        data, digest = cloud.sha256_file(path, max_bytes=2_000_000)
        mpeg_sync = len(data) > 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0
        if not (mpeg_sync or data.startswith(b"ID3")) or digest != meta.get("sha256"):
            raise cloud.UploadError(f"{name}: not an MP3 or hash differs from manifest.json.")
        result[name] = {"data": data, "hash": digest}
    return result


def collect_ids() -> dict:
    """{name: assetId} from every set's receipts, only where the receipt matches the current file."""
    ids = {}
    for set_name, directory in SETS.items():
        manifest = cloud.read_json(directory / "manifest.json", {})
        receipts = cloud.read_json(directory / "upload-receipts.json", {})
        for name, meta in manifest.items():
            receipt = receipts.get(name)
            if isinstance(receipt, dict) and receipt.get("hash") == meta.get("sha256"):
                if name in ids:
                    raise cloud.UploadError(f"sound {name} exists in two sets")
                ids[name] = int(receipt["assetId"])
            else:
                ids.setdefault(name, 0)
    return ids


def write_config(ids: dict) -> None:
    """Replace the generated SFX_IDS block in SoundAssets.luau (markers must exist)."""
    rows = "".join(f"\t{name} = {ids[name]},\n" for name in sorted(ids))
    block = (
        "-- BEGIN GENERATED SFX IDS (tools/audio/upload_sfx.py)\n"
        "local SFX_IDS: { [string]: number } = {\n" + rows + "}\n"
        "-- END GENERATED SFX IDS"
    )
    text = CONFIG.read_text(encoding="utf-8")
    pattern = re.compile(r"-- BEGIN GENERATED SFX IDS.*?-- END GENERATED SFX IDS", re.S)
    if not pattern.search(text):
        raise cloud.UploadError("SoundAssets.luau lost its generated-SFX markers.")
    CONFIG.write_text(pattern.sub(lambda _m: block, text), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--user-id")
    parser.add_argument("--set", nargs="+", choices=sorted(SETS), default=sorted(SETS))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--sync-only", action="store_true")
    parser.add_argument("--abandon", nargs="*", default=[])
    args = parser.parse_args()
    if args.sync_only:
        write_config(collect_ids())
        print("[sfx-upload] SoundAssets.luau SFX_IDS regenerated from receipts")
        return 0
    if args.user_id is None or not cloud.ASSET_ID.fullmatch(args.user_id):
        parser.error("--user-id must be a positive integer")
    sources = {name: validate(SETS[name]) for name in args.set}
    if args.dry_run:
        print(f"[sfx-upload] validated {sum(len(s) for s in sources.values())} MP3s; no network requests")
        return 0
    creator = {"userId": args.user_id}
    client = cloud.Client(cloud.read_key(), timeout=60)
    for set_name, files in sources.items():
        directory = SETS[set_name]
        for name, source in files.items():
            with cloud.exclusive(directory, cloud.UPLOAD_LOCK):
                identity = {"hash": source["hash"], "creator": creator, "assetType": "Audio"}
                receipt = cloud.journaled_upload(
                    directory,
                    name,
                    identity,
                    lambda s=source, n=name: client.create_asset(
                        "Audio",
                        f"SellNukes SFX {n}"[:50],
                        "Original synthesised SellNukes sound effect.",
                        creator,
                        f"{n}.mp3",
                        "audio/mpeg",
                        s["data"],
                    ),
                    client,
                    abandon=name in args.abandon,
                )
            print(f"[sfx-upload] {set_name}/{name}: audio {receipt['assetId']} ({receipt['moderation']})", flush=True)
    write_config(collect_ids())
    print("[sfx-upload] SoundAssets.luau SFX_IDS regenerated")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except cloud.UploadError as error:
        print(f"[sfx-upload] {error}", file=sys.stderr)
        sys.exit(1)
