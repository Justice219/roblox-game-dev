#!/usr/bin/env python3
"""Launch the pinned Roblox Studio MCP with a private Open Cloud key that is never logged.

Copy to ~/.local/bin/robloxstudio-mcp-codex and chmod 700. Run ONE primary process, stdin held open:
    tail -f /dev/null | ~/.local/bin/robloxstudio-mcp-codex
Put the key (only needed for upload_asset and similar tools) in a mode-600 file at the path below.
"""
import os
import shutil
import sys
from pathlib import Path

key_file = Path.home() / ".config/robloxstudio-mcp/open-cloud-key"
env = os.environ.copy()
if key_file.is_file():
    env["ROBLOX_OPEN_CLOUD_API_KEY"] = key_file.read_text().strip()
npx = shutil.which("npx")
if npx is None:
    sys.exit("npx not found: install Node.js first")
os.execvpe(npx, ["npx", "-y", "@chrrxs/robloxstudio-mcp@3.2.1", "--auto-install-plugin"], env)
