"""
snkit.cloud — Roblox Open Cloud transport + durable upload journal for SellNukes art.

Pure Python (no bpy): imported by tools/ui/upload_world_studs.py (stud images) and
tools/blender/upload_meshes.py (Blender FBX models). Ported from RoBeasts'
tools/blender/upload_arena_art.py + tools/audio/upload_audio.py, generalised to any asset type.

Security model (unchanged from RoBeasts):
    * The API key is read from $ROBLOX_OPEN_CLOUD_KEY or a mode-600 env file you own
      (~/.config/robeasts/open-cloud.env, line `ROBLOX_OPEN_CLOUD_KEY=...`). It is never accepted on
      argv, never printed, never written anywhere, and only sent to apis.roblox.com.
    * Fixed host, TLS verified, ambient proxies disabled, redirects refused (an authenticated
      request can never be forwarded), response bodies bounded, remote error bodies never echoed.
    * Asset downloads follow the asset-delivery `location` ONLY to https://*.rbxcdn.com or the exact
      host contentdelivery.roblox.com (Roblox's asset-delivery started returning that host on
      2026-10-30) and send NO credentials there.

Durability model (journal + receipts):
    * journal (upload-operations.json) records intent BEFORE the POST ("submitting") and the
      operation path BEFORE polling ("pending"). A crash during the POST leaves "submitting", which
      blocks an automatic duplicate create: check Creator Dashboard, then either record the asset
      by hand or rerun with --abandon <key> to accept a possible orphan and upload again.
    * receipts (upload-receipts.json) record finished uploads bound to the exact content hash and
      creator. A rerun with the same content skips the upload entirely (idempotent); changed
      content (new hash) uploads a new asset and keeps the old receipt under "history".

Example:
    from snkit import cloud
    client = cloud.Client(cloud.read_key())
    receipt = cloud.journaled_upload(directory, "BuyPad", identity, lambda: client.create_asset(...), client)
"""

from __future__ import annotations

import fcntl
import gzip
import hashlib
import http.client
import io
import json
import os
import re
import ssl
import stat
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Callable

BASE_URL = "https://apis.roblox.com/"
CREATE_PATH = "assets/v1/assets"
OPERATION = re.compile(r"operations/[A-Za-z0-9_-]{1,200}\Z")
NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,100}\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")
ASSET_ID = re.compile(r"[1-9][0-9]{0,18}\Z")
MAX_BYTES = 20_000_000  # Open Cloud model/image upload ceiling we accept locally
MAX_RESPONSE = 1_048_576
DEFAULT_KEY_FILE = "~/.config/robeasts/open-cloud.env"
# Exact (non-wildcard) Roblox CDN hosts the credential-free download hop may use besides *.rbxcdn.com.
CDN_HOSTS = frozenset({"contentdelivery.roblox.com"})
MACOS_CA_BUNDLE = "/etc/ssl/cert.pem"


class UploadError(Exception):
    """A deliberately sanitised diagnostic, safe to print beside an API-key workflow."""


# ------------------------------------------------------------------------------------------------
# Local state helpers
# ------------------------------------------------------------------------------------------------


def atomic_json(path: Path, value) -> None:
    """Fsync + atomically replace a JSON file in its own directory (never a half-written journal)."""
    fd, temporary = tempfile.mkstemp(prefix=".sn-upload-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path: Path, missing=None):
    """Read a JSON object without echoing its contents; `missing` is returned for absent files."""
    if not path.exists() and missing is not None:
        return missing
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise UploadError(f"Cannot read valid JSON from {path.name}.") from None
    if not isinstance(value, dict):
        raise UploadError(f"{path.name} must contain a JSON object.")
    return value


def sha256_file(path: Path, max_bytes: int = MAX_BYTES) -> tuple[bytes, str]:
    """Read a bounded regular (non-symlink) file and return (bytes, sha256 hex)."""
    if path.is_symlink() or not path.is_file():
        raise UploadError(f"{path.name} must be a regular file.")
    size = path.stat().st_size
    if not 0 < size <= max_bytes:
        raise UploadError(f"{path.name} must be non-empty and at most {max_bytes} bytes.")
    data = path.read_bytes()
    return data, hashlib.sha256(data).hexdigest()


def read_key(env_file: str = DEFAULT_KEY_FILE) -> str:
    """
    ROBLOX_OPEN_CLOUD_KEY from the environment or a private env file. Never printed or persisted.

    The file must be a regular file owned by the current user with no group/other permissions.
    """
    key = os.environ.get("ROBLOX_OPEN_CLOUD_KEY", "").strip()
    if not key:
        path = Path(env_file).expanduser()
        try:
            info = path.lstat()
        except OSError:
            raise UploadError("Open Cloud key file not found (expected ~/.config/robeasts/open-cloud.env).") from None
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise UploadError("Refusing the key file: it must be a regular file you own with mode 600.")
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line.startswith("export "):
                line = line[len("export ") :]
            if line.startswith("ROBLOX_OPEN_CLOUD_KEY="):
                key = line.split("=", 1)[1].strip().strip("'\"")
                break
    if not key or len(key) > 16384 or any(ord(c) < 33 or ord(c) > 126 for c in key):
        raise UploadError("ROBLOX_OPEN_CLOUD_KEY missing or malformed (the key is never printed).")
    return key


UPLOAD_LOCK = ".sn-upload.lock"  # journal, receipts, mesh-ids.json (upload_meshes / upload_world_studs)
MANIFEST_LOCK = ".sn-manifest.lock"  # manifest.json + MeshAssets.luau (generate_world / sync_meshes)
DEFAULT_LOCK_WAIT = 1800.0  # seconds a builder waits for another builder's turn before giving up


@contextmanager
def exclusive(directory: Path, name: str = UPLOAD_LOCK, wait: float | None = DEFAULT_LOCK_WAIT):
    """
    Process-exclusive advisory lock (fcntl.flock on <directory>/<name>) around a read-modify-write
    of shared pipeline state, so parallel art builders never drop each other's entries and two
    uploaders can never race one journal into duplicate assets.

    wait: seconds to block for the lock (polling every 0.25 s); None = fail immediately.
    The kernel releases the lock if the holder dies, so a crash never wedges other builders.

    Example:
        with cloud.exclusive(DIRECTORY, cloud.MANIFEST_LOCK):
            manifest = cloud.read_json(path, {}); manifest.update(mine); cloud.atomic_json(path, manifest)
    """
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / name).open("a") as handle:
        deadline = time.monotonic() + (wait or 0.0)
        announced = False
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if wait is None or time.monotonic() >= deadline:
                    raise UploadError(f"Timed out waiting for {name} (another builder holds it).") from None
                if not announced:
                    print(f"[lock] waiting for {name} (another builder is using it)...", flush=True)
                    announced = True
                time.sleep(0.25)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


# ------------------------------------------------------------------------------------------------
# HTTPS transport
# ------------------------------------------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward an authenticated request through any redirect."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401 - urllib API
        return None


def _tls_context() -> ssl.SSLContext:
    """Certificate-verifying TLS ($SSL_CERT_FILE, else the macOS system bundle, else defaults)."""
    cafile = os.environ.get("SSL_CERT_FILE") or (MACOS_CA_BUNDLE if os.path.exists(MACOS_CA_BUNDLE) else None)
    return ssl.create_default_context(cafile=cafile)


class Client:
    """Fixed-host Open Cloud client: create assets, poll operations, download owned models."""

    def __init__(self, key: str, timeout: int = 60):
        self.key = key
        self.timeout = timeout
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            _NoRedirect(),
            urllib.request.HTTPSHandler(context=_tls_context()),
        )

    def _json(self, request: urllib.request.Request) -> dict:
        """Perform one request, bounded and redacted; return the decoded JSON object."""
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                raw = response.read(MAX_RESPONSE + 1)
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            raise UploadError(f"Open Cloud returned HTTP {status}; response body omitted.") from None
        except (OSError, urllib.error.URLError, http.client.HTTPException):
            raise UploadError("Open Cloud request failed; details omitted to protect credentials.") from None
        if len(raw) > MAX_RESPONSE:
            raise UploadError("Open Cloud response exceeded the size limit.")
        try:
            result = json.loads(raw or b"{}")
        except ValueError:
            raise UploadError("Open Cloud returned invalid JSON.") from None
        if not isinstance(result, dict):
            raise UploadError("Open Cloud returned a non-object response.")
        return result

    def poll(self, operation: str) -> dict:
        """GET one validated operation path (assets/v1/operations/<id>)."""
        if not OPERATION.fullmatch(operation):
            raise UploadError("Rejected an invalid operation path.")
        request = urllib.request.Request(
            BASE_URL + "assets/v1/" + operation, headers={"x-api-key": self.key, "Accept": "application/json"}
        )
        return self._json(request)

    def create_asset(
        self, asset_type: str, display_name: str, description: str, creator: dict, filename: str, mime: str, data: bytes
    ) -> dict:
        """
        POST one multipart asset create (official schema). Returns the operation object.

        asset_type: "Model" (FBX), "Image" (PNG) or "Audio" (MP3). display_name <= 50 chars.
        """
        allowed = {"Model": "model/fbx", "Image": "image/png", "Audio": "audio/mpeg"}
        if allowed.get(asset_type) != mime:
            raise UploadError("Rejected an unsupported asset type.")
        if not NAME.fullmatch(filename.split(".")[0]) or len(display_name) > 50:
            raise UploadError("Rejected an invalid asset name.")
        boundary = "SellNukes" + uuid.uuid4().hex
        metadata = {
            "assetType": asset_type,
            "displayName": display_name,
            "description": description,
            "creationContext": {"creator": creator},
        }
        body = (
            f'--{boundary}\r\nContent-Disposition: form-data; name="request"\r\n'
            "Content-Type: application/json\r\n\r\n"
        ).encode() + json.dumps(metadata).encode()
        body += (
            f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="fileContent"; '
            f'filename="{filename}"\r\nContent-Type: {mime}\r\n\r\n'
        ).encode()
        body += data + f"\r\n--{boundary}--\r\n".encode()
        request = urllib.request.Request(
            BASE_URL + CREATE_PATH,
            data=body,
            method="POST",
            headers={
                "x-api-key": self.key,
                "Accept": "application/json",
                "Content-Type": "multipart/form-data; boundary=" + boundary,
            },
        )
        return self._json(request)

    def download_model(self, model_id: int) -> bytes:
        """
        Download an owned Model asset (rbxm/rbxmx bytes) through asset-delivery, then the CDN.

        The second hop carries no credentials and must be https://*.rbxcdn.com or an exact host in
        CDN_HOSTS (no redirects).
        Gzip payloads are decompressed with a bounded reader (never unbounded gzip.decompress).
        """
        if type(model_id) is not int or not 0 < model_id < 2**53:
            raise UploadError("Invalid model id.")
        url = f"{BASE_URL}asset-delivery-api/v1/assetId/{model_id}"
        meta = self._json(urllib.request.Request(url, headers={"x-api-key": self.key, "Accept": "application/json"}))
        location = meta.get("location")
        address = urllib.parse.urlsplit(location) if isinstance(location, str) else None
        if (
            address is None
            or address.scheme != "https"
            or not address.hostname
            or not (address.hostname.endswith(".rbxcdn.com") or address.hostname in CDN_HOSTS)
            or address.port not in (None, 443)
            or address.username
            or address.password
            or address.fragment
        ):
            raise UploadError("Asset delivery returned an untrusted CDN location.")
        try:
            with self.opener.open(urllib.request.Request(location), timeout=self.timeout) as response:
                data = response.read(MAX_BYTES + 1)
        except (OSError, urllib.error.URLError, http.client.HTTPException):
            raise UploadError("CDN download failed; details omitted.") from None
        if data.startswith(b"\x1f\x8b"):
            with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
                data = compressed.read(MAX_BYTES + 1)
        if not 0 < len(data) <= MAX_BYTES or not data.startswith(b"<roblox"):
            raise UploadError("Asset delivery returned invalid model data.")
        return data


# ------------------------------------------------------------------------------------------------
# Durable journal: one asset per (key, content hash)
# ------------------------------------------------------------------------------------------------


def journaled_upload(
    directory: Path,
    key: str,
    identity: dict,
    create: Callable[[], dict],
    client: Client,
    poll_timeout: float = 300,
    poll_interval: float = 3,
    abandon: bool = False,
) -> dict:
    """
    Upload one asset exactly once for this (key, identity) and return its receipt.

    identity: dict that fully describes the content + owner, e.g. {"hash": sha, "creator": {...}}.
              Same identity -> the existing receipt is returned without any network call.
    create:   zero-arg callable doing the POST (called only after intent is journaled).
    abandon:  drop a "submitting"/"failed" journal entry for this key first (owner-acknowledged,
              e.g. after confirming in Creator Dashboard that the asset was not created).

    Receipt shape: {**identity, "assetId": int, "moderation": str, "uploadedAt": unix seconds}.
    """
    if not NAME.fullmatch(key):
        raise UploadError("Invalid upload key.")
    journal_path = directory / "upload-operations.json"
    receipt_path = directory / "upload-receipts.json"
    journal = read_json(journal_path, {})
    receipts = read_json(receipt_path, {})
    receipt = receipts.get(key)
    if isinstance(receipt, dict) and all(receipt.get(k) == v for k, v in identity.items()):
        if type(receipt.get("assetId")) is int and receipt["assetId"] > 0:
            return receipt
    entry = journal.get(key)
    if entry is not None and any(entry.get(k) != v for k, v in identity.items()):
        if entry.get("status") == "complete" or abandon:
            entry = None  # stale journal for older content; superseded below
        else:
            raise UploadError(
                f"{key}: an unfinished upload for different content is journaled; "
                "rerun with --abandon " + key + " after checking Creator Dashboard."
            )
    if entry is not None and abandon and entry.get("status") in ("submitting", "failed"):
        entry = None
    if entry is None:
        entry = {**identity, "status": "submitting"}
        journal[key] = entry
        atomic_json(journal_path, journal)  # intent persisted BEFORE the network call
        response = create()
        operation = response.get("path")
        if not isinstance(operation, str) or not OPERATION.fullmatch(operation):
            raise UploadError(f"{key}: create returned no operation path; reconcile before retrying.")
        entry.update(status="pending", operation=operation)
        atomic_json(journal_path, journal)
    elif entry.get("status") == "submitting":
        raise UploadError(f"{key}: prior POST outcome unknown; check Creator Dashboard, then --abandon {key}.")
    elif entry.get("status") == "failed":
        raise UploadError(f"{key}: operation failed earlier (moderation/format); fix and --abandon {key}.")
    deadline = time.monotonic() + poll_timeout
    while entry.get("status") == "pending":
        response = client.poll(entry["operation"])
        if response.get("done") is True:
            asset = response.get("response") if isinstance(response.get("response"), dict) else {}
            asset_id = asset.get("assetId")
            if response.get("error") or not ASSET_ID.fullmatch(str(asset_id)):
                entry["status"] = "failed"
                atomic_json(journal_path, journal)
                raise UploadError(f"{key}: upload operation failed or returned no asset id.")
            moderation = (asset.get("moderationResult") or {}).get("moderationState", "unknown")
            entry.update(status="complete", assetId=int(asset_id), moderation=moderation)
            atomic_json(journal_path, journal)
            break
        if time.monotonic() >= deadline:
            raise UploadError(f"{key}: polling timed out; rerun to resume the saved operation.")
        time.sleep(poll_interval)
    if type(entry.get("assetId")) is not int:
        raise UploadError(f"{key}: journal has no completed asset id.")
    new_receipt = {
        **identity,
        "assetId": entry["assetId"],
        "moderation": entry.get("moderation", "unknown"),
        "uploadedAt": int(time.time()),
    }
    history = receipts.setdefault("_history", {})
    if isinstance(receipt, dict) and receipt.get("assetId") != entry["assetId"]:
        history.setdefault(key, []).append(receipt)  # keep superseded uploads auditable
    receipts[key] = new_receipt
    atomic_json(receipt_path, receipts)
    return new_receipt
