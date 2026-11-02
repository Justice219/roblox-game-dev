"""
opencloud.py — minimal, hardened Roblox Open Cloud client for the SellNukes icon pipeline.

Purpose:
    tools/ui/icons/icons.py uploads every icon PNG as an Image asset and later refreshes each
    asset's moderation state. This module is the only code that touches the network with the API
    key. It is self-contained (stdlib only) so the icon tool never breaks when other builders'
    helpers change.

Security model (same as RoBeasts tools/blender/upload_arena_art.py and snkit/cloud.py):
    * The key comes from $ROBLOX_OPEN_CLOUD_KEY, else ~/.config/robeasts/open-cloud.env (line
      `ROBLOX_OPEN_CLOUD_KEY=...`), else ~/.config/robloxstudio-mcp/open-cloud-key (the bare key).
      Key files must be regular files owned by the current user with mode 600 (no group / other
      bits). The key is never accepted on argv, never printed, never written anywhere.
    * One fixed host (apis.roblox.com), verified TLS, ambient proxies disabled, redirects refused
      (an authenticated request can never be forwarded), bounded responses, remote error bodies
      never echoed (they could reflect request data).
    * Only three request shapes exist: POST assets/v1/assets (create), GET assets/v1/operations/<id>
      (poll) and GET assets/v1/assets/<numeric id>?readMask=moderationResult (moderation). Paths
      are validated against strict patterns before any request is built.

Example:
    client = Client(read_key())
    response = client.create_image("SellNukes icon: Shop", "description", png_bytes, "Shop.png", {"userId": "1"})
    asset = client.poll(response["path"])
"""

from __future__ import annotations

import http.client
import json
import os
import re
import ssl
import stat
import urllib.error
import urllib.request
import uuid
from pathlib import Path

BASE_URL = "https://apis.roblox.com/"
OPERATION = re.compile(r"operations/[A-Za-z0-9_-]{1,200}\Z")
ASSET_ID = re.compile(r"[1-9][0-9]{0,18}\Z")
FILE_NAME = re.compile(r"[A-Za-z0-9_.-]{1,80}\Z")
MAX_RESPONSE = 1_048_576
KEY_FILES = (
    ("~/.config/robeasts/open-cloud.env", "env"),
    ("~/.config/robloxstudio-mcp/open-cloud-key", "raw"),
)
MACOS_CA_BUNDLE = "/etc/ssl/cert.pem"


class CloudError(Exception):
    """A sanitised failure: safe to print next to an API-key workflow (no bodies, no headers)."""


def _valid_key(key: str) -> bool:
    """A plausible key: printable ASCII, no whitespace, bounded length."""
    return bool(key) and len(key) <= 16384 and all(33 <= ord(c) <= 126 for c in key)


def _private_file(path: Path) -> bool:
    """True when `path` is a regular file we own with no group / other permission bits."""
    try:
        info = path.lstat()
    except OSError:
        return False
    if not stat.S_ISREG(info.st_mode):
        return False
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise CloudError(f"Refusing {path.name}: it must be a regular file you own with mode 600.")
    return True


def key_candidates() -> list[tuple[str, str]]:
    """
    Every usable Open Cloud key as (label, key), in priority order: $ROBLOX_OPEN_CLOUD_KEY, then
    each private key file. Labels name the SOURCE only ("env", "robeasts-env", "studio-mcp-file");
    keys are never printed, logged or persisted. Used by tools/monetization/publish.py to probe
    which key carries which scopes.
    """
    found: list[tuple[str, str]] = []
    key = os.environ.get("ROBLOX_OPEN_CLOUD_KEY", "").strip()
    if key:
        if not _valid_key(key):
            raise CloudError("ROBLOX_OPEN_CLOUD_KEY is malformed (the key is never printed).")
        found.append(("env", key))
    for (raw_path, kind), label in zip(KEY_FILES, ("robeasts-env", "studio-mcp-file")):
        path = Path(raw_path).expanduser()
        if not _private_file(path):
            continue
        text = path.read_text(encoding="utf-8")
        key = ""
        if kind == "raw":
            key = text.strip()
        else:
            for line in text.splitlines():
                line = line.strip()
                if line.startswith("export "):
                    line = line[len("export ") :]
                if line.startswith("ROBLOX_OPEN_CLOUD_KEY="):
                    key = line.split("=", 1)[1].strip().strip("'\"")
                    break
        if _valid_key(key):
            found.append((label, key))
    return found


def read_key() -> str:
    """
    The first available Open Cloud API key (see key_candidates). Never printed, logged or
    persisted. Raises CloudError when none is available.
    """
    found = key_candidates()
    if not found:
        raise CloudError("No Open Cloud key found ($ROBLOX_OPEN_CLOUD_KEY or a mode-600 key file).")
    return found[0][1]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward an authenticated request (including a POST) through any redirect."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401 - urllib API
        """Returning None makes urllib fail instead of sending credentials elsewhere."""
        return None


def _tls_context() -> ssl.SSLContext:
    """Verified TLS; framework Pythons on macOS may lack certifi, so fall back to the system CAs."""
    if Path(MACOS_CA_BUNDLE).is_file():
        return ssl.create_default_context(cafile=MACOS_CA_BUNDLE)
    return ssl.create_default_context()


class Client:
    """Fixed-host HTTPS transport with verified TLS, bounded responses and no automatic retries."""

    def __init__(self, key: str, timeout: float = 30.0):
        """Disable proxies and redirects; the key stays in this process's memory only."""
        self._key = key
        self.timeout = timeout
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            _NoRedirect(),
            urllib.request.HTTPSHandler(context=_tls_context()),
        )

    def _request(self, path: str, body: bytes | None = None, content_type: str | None = None) -> dict:
        """One request to BASE_URL + path (already validated by the caller). Redacts all failures."""
        headers = {"x-api-key": self._key, "Accept": "application/json"}
        if content_type:
            headers["Content-Type"] = content_type
        request = urllib.request.Request(
            BASE_URL + path, data=body, headers=headers, method="POST" if body is not None else "GET"
        )
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                raw = response.read(MAX_RESPONSE + 1)
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            raise CloudError(f"Open Cloud returned HTTP {status}; response body omitted.") from None
        except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException):
            raise CloudError("Open Cloud request failed; details omitted to protect credentials.") from None
        if len(raw) > MAX_RESPONSE:
            raise CloudError("Open Cloud response exceeded the size limit.")
        try:
            result = json.loads(raw or b"{}")
        except ValueError:
            raise CloudError("Open Cloud returned invalid JSON.") from None
        if not isinstance(result, dict):
            raise CloudError("Open Cloud returned an invalid response object.")
        return result

    def create_image(self, display_name: str, description: str, data: bytes, file_name: str, creator: dict) -> dict:
        """
        POST assets/v1/assets: create one Image asset (multipart: JSON request + PNG bytes).
        Returns the operation object ({"path": "operations/<id>", ...}). Never retried here: an
        ambiguous POST must be reconciled by the caller's journal, not repeated blindly.
        """
        if not FILE_NAME.fullmatch(file_name):
            raise CloudError("Rejected an unsafe upload file name.")
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise CloudError("Only PNG images are uploaded.")
        boundary = "SellNukesIcon" + uuid.uuid4().hex
        metadata = {
            "assetType": "Image",
            "displayName": display_name[:50],
            "description": description[:1000],
            "creationContext": {"creator": creator},
        }
        body = (
            f'--{boundary}\r\nContent-Disposition: form-data; name="request"\r\n'
            "Content-Type: application/json\r\n\r\n"
        ).encode() + json.dumps(metadata).encode()
        body += (
            f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="fileContent"; '
            f'filename="{file_name}"\r\nContent-Type: image/png\r\n\r\n'
        ).encode()
        body += data + f"\r\n--{boundary}--\r\n".encode()
        return self._request("assets/v1/assets", body, "multipart/form-data; boundary=" + boundary)

    def poll(self, operation: str) -> dict:
        """GET one validated operation path (assets/v1/operations/<id>)."""
        if not isinstance(operation, str) or not OPERATION.fullmatch(operation):
            raise CloudError("Rejected an invalid operation path.")
        return self._request("assets/v1/" + operation)

    def moderation(self, asset_id: int) -> str:
        """The asset's moderationResult.moderationState ("Approved" / "Reviewing" / "Rejected"),
        or "unknown". The id is a validated integer, so no caller text reaches the URL."""
        if type(asset_id) is not int or not ASSET_ID.fullmatch(str(asset_id)):
            raise CloudError("Invalid asset id.")
        result = self._request(f"assets/v1/assets/{asset_id}?readMask=moderationResult")
        moderation = result.get("moderationResult")
        state = moderation.get("moderationState") if isinstance(moderation, dict) else None
        return state if isinstance(state, str) and re.fullmatch(r"[A-Za-z]{1,32}", state) else "unknown"
