#!/usr/bin/env python3
"""
studio_mcp.py — call the Roblox Studio MCP (@chrrxs/robloxstudio-mcp v3.x) from the shell.

WHY THIS EXISTS
    The "MCP Server" plugin inside Roblox Studio (toolbar: Plugins -> MCP Server, panel shows
    "MCP v3.2.1 · github Chrrxs/robloxstudio-mcp · http://localhost:58741") talks to ONE primary
    node process that owns 127.0.0.1:58741. Whichever agent started first (often Codex in the
    RoBeasts repo) owns it. Other agents can still drive Studio through that primary's
    streamable-HTTP MCP endpoint `POST /mcp`, authenticated with the token stored in
    `~/.robloxstudio-mcp/auth-token`. This script does exactly that, so any Claude session or
    subagent can use Studio through Bash, without registering a new MCP server or restarting.

    NOTE: this is NOT the older custom bridge in `RobloxGame/roblox-studio-mcp` (port 3001,
    "MCPBridge" plugin). That one is not what Studio is connected to for SellNukes.

SECURITY
    * Only talks to 127.0.0.1 (never a remote host).
    * Reads the token from the file at call time and never prints it.
    * Lua source passed to execute_luau comes from the developer's own repo/scratch files.

USAGE
    scripts/studio_mcp.py list                                   # list tool names
    scripts/studio_mcp.py schema execute_luau                    # print one tool's input schema
    scripts/studio_mcp.py call get_services '{}'                 # call a tool with JSON args
    scripts/studio_mcp.py luau 'print(workspace:GetChildren())'  # shortcut: run Luau in edit mode
    scripts/studio_mcp.py luau-file path/to/snippet.luau         # run a Luau file in edit mode

    Example (count parts in a plot):
        scripts/studio_mcp.py luau 'return #workspace.Plots.Plot1:GetDescendants()'
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("ROBLOX_STUDIO_PORT", "58741"))
URL = f"http://{HOST}:{PORT}/mcp"
TOKEN_FILE = Path.home() / ".robloxstudio-mcp" / "auth-token"
TIMEOUT_S = float(os.environ.get("STUDIO_MCP_TIMEOUT", "120"))


def _token() -> str:
    """Read the shared bridge auth token (created by the primary robloxstudio-mcp process)."""
    env = os.environ.get("ROBLOX_STUDIO_AUTH_TOKEN")
    if env:
        return env.strip()
    return TOKEN_FILE.read_text().strip()


def _post(payload: dict, session: str | None) -> tuple[dict | None, str | None]:
    """POST one JSON-RPC message; parse either a JSON body or an SSE `data:` frame.

    Returns (decoded JSON-RPC response or None for notifications, session id header).
    """
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "X-MCP-Auth": _token(),
    }
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        sid = resp.headers.get("mcp-session-id") or session
        body = resp.read().decode("utf-8", "replace")
    if not body.strip():
        return None, sid
    if body.lstrip().startswith("{"):
        return json.loads(body), sid
    # Server-sent events: take the last `data:` line that carries our response id.
    result = None
    for line in body.splitlines():
        if line.startswith("data:"):
            try:
                msg = json.loads(line[5:].strip())
            except json.JSONDecodeError:
                continue
            if "id" in msg and msg.get("id") == payload.get("id"):
                result = msg
    return result, sid


def _session() -> str | None:
    """Run the MCP initialize handshake and return the session id."""
    init = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "sellnukes-cli", "version": "1.0"},
        },
    }
    _, sid = _post(init, None)
    _post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    return sid


def rpc(method: str, params: dict) -> dict:
    """Open a session and perform one JSON-RPC call; raise on protocol error."""
    sid = _session()
    resp, _ = _post({"jsonrpc": "2.0", "id": 2, "method": method, "params": params}, sid)
    if resp is None:
        raise RuntimeError("empty response from Studio MCP")
    if "error" in resp:
        raise RuntimeError(json.dumps(resp["error"]))
    return resp["result"]


# Owner R72 (2026-10-31): "stop running multiplayer playtests". An orphaned 8-client multiplayer
# test (its start was reported as "not detected", so the caller never ended it) ran for 7 h,
# exhausted the Mac's memory and hung Studio + the MCP. Starting one is refused here, the single
# choke point every agent and QA script goes through. Only "status" and "end" stay allowed, so a
# stray multiplayer test can still be inspected and stopped. Solo playtests are unaffected.
MULTIPLAYER_ALLOWED_ACTIONS = frozenset({"status", "end", "stop"})


def guard_tool(name: str, args: dict) -> None:
    """Raise before any banned Studio action leaves this machine.

    Example:
        guard_tool("multiplayer_playtest", {"action": "start"})  # -> RuntimeError (owner R72)
        guard_tool("multiplayer_playtest", {"action": "end"})    # -> None (allowed: stops one)
    """
    if name == "multiplayer_playtest":
        action = str((args or {}).get("action", "")).lower()
        if action not in MULTIPLAYER_ALLOWED_ACTIONS:
            raise RuntimeError(
                "multiplayer_playtest is banned by the owner (R72: 'stop running multiplayer playtests'). "
                "Use solo_playtest instead; only status/end are allowed to stop a stray one."
            )


def call_tool(name: str, args: dict) -> str:
    """Call a tool and flatten its text content blocks into one string (banned actions refused first)."""
    guard_tool(name, args)
    result = rpc("tools/call", {"name": name, "arguments": args})
    parts = [c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"]
    text = "\n".join(parts)
    if result.get("isError"):
        raise RuntimeError(text)
    return text


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    try:
        if cmd == "list":
            tools = rpc("tools/list", {}).get("tools", [])
            for t in tools:
                desc = (t.get("description") or "").split("\n")[0][:110]
                print(f"{t['name']}: {desc}")
        elif cmd == "schema":
            tools = rpc("tools/list", {}).get("tools", [])
            match = [t for t in tools if t["name"] == argv[2]]
            print(json.dumps(match[0] if match else {}, indent=2))
        elif cmd == "call":
            args = json.loads(argv[3]) if len(argv) > 3 else {}
            print(call_tool(argv[2], args))
        elif cmd in ("luau", "luau-file"):
            code = Path(argv[2]).read_text() if cmd == "luau-file" else argv[2]
            print(call_tool("execute_luau", {"code": code}))
        else:
            print(f"unknown command {cmd}")
            return 2
    except Exception as exc:  # surface a short error to the caller's shell
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
