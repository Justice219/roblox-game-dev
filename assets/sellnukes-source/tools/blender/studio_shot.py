#!/usr/bin/env python3
"""
studio_shot.py — save a Roblox Studio viewport screenshot to a file (for art verification).

scripts/studio_mcp.py flattens tool results to text, dropping the image block that the Studio
MCP's `capture_screenshot` returns. This helper reuses its authenticated localhost transport
(127.0.0.1:58741, token read from ~/.robloxstudio-mcp/auth-token, never printed) and writes the
image bytes to disk.

Optionally runs a Luau file first (e.g. to position the camera) via execute_luau in edit mode.

Usage:
    python3 tools/blender/studio_shot.py docs/verification/world-art/garage.jpg [--luau setup.luau] [--png]

Example (camera + shot):
    python3 tools/blender/studio_shot.py /tmp/x.jpg --luau tools/blender/studio/frame_camera.luau
"""
from __future__ import annotations

import argparse
import base64
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import studio_mcp  # noqa: E402  (repo-local transport; localhost only)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("output", type=Path)
    parser.add_argument("--luau", type=Path, help="Luau file to execute (edit mode) before capturing")
    parser.add_argument("--png", action="store_true", help="lossless PNG instead of JPEG")
    args = parser.parse_args()
    if args.luau is not None:
        print(studio_mcp.call_tool("execute_luau", {"code": args.luau.read_text()}))
    fmt = "png" if args.png else "jpeg"
    result = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": fmt, "quality": 88}})
    images = [c for c in result.get("content", []) if c.get("type") == "image" and c.get("data")]
    if result.get("isError") or not images:
        print("capture failed: no image returned", file=sys.stderr)
        return 1
    data = base64.b64decode(images[0]["data"], validate=True)
    if len(data) > 25_000_000:
        print("capture too large", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f"saved {args.output} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
