#!/usr/bin/env python3
"""Create / update every SellNukes game pass and developer product on Roblox (Open Cloud).

Owner rule: every system is live and tracked; the lead (2026-10-30): "create every game pass +
developer product in MonetizationConfig ... with its name, kid-friendly description, Robux price,
for_sale = true, and its icon from assets/icons/".

What it does (idempotent; safe to rerun at any time):
    1. Reads the catalogue from the REAL shipped MonetizationConfig (tools/monetization/
       dump_catalogue.luau through Lune), so names / descriptions / prices never drift.
    2. Lists what already exists in the universe (read-only GET .../creator, paginated).
    3. Matches each catalogue item to an existing one by its recorded id (state.json), else by
       exact name, so an item is NEVER created twice. Only missing items are created; existing
       ones are PATCHed with just the fields that differ (name, description, price, for-sale,
       icon when the local PNG's sha256 changed).
    4. Writes the ids into src/shared/Config/PublishedProductIds.luau (keeps its shape/comments)
       and the catalogue table into docs/monetization.md.

Durability: state.json records every create intent BEFORE the POST ("creating") and the id
after it. A crash mid-POST is reconciled on the next run by name (the item exists -> adopt it).
If it still does not exist, the run refuses to create it again unless --retry-creating is passed
(an eventually-consistent list must never cause a duplicate).

Security: keys come from tools/ui/icons/opencloud.key_candidates() (env or mode-600 files),
never argv; never printed. One fixed host, verified TLS, no proxies, no redirects, bounded
responses, error bodies summarised (no echo of request data), every path matched against a
strict pattern. Only list / get / create / patch of passes and products in ONE universe exist.

Usage:
    python3 tools/monetization/publish.py probe              # which key has which read scope
    python3 tools/monetization/publish.py plan               # dry run: what would change
    python3 tools/monetization/publish.py publish [--key-source robeasts-env] [--retry-creating]
    python3 tools/monetization/publish.py status             # catalogue vs recorded ids
    python3 tools/monetization/publish.py write              # regenerate ids Luau + docs from state
    (--dry-run on publish == plan)
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
UNIVERSE_ID = 10773845696  # "Sell Nukes" (place 132667741281890), owned by user 1586034782
STATE = ROOT / "tools/monetization/state.json"
IDS_LUAU = ROOT / "src/shared/Config/PublishedProductIds.luau"
DOCS = ROOT / "docs/monetization.md"
ICON_DIR = ROOT / "assets/icons"
DUMP_SCRIPT = ROOT / "tools/monetization/dump_catalogue.luau"
BASE_URL = "https://apis.roblox.com/"
MAX_RESPONSE = 2_097_152
MAX_ICON_BYTES = 4_194_304
MAX_PAGES = 50

# Open Cloud shapes per kind (verified against @chrrxs/robloxstudio-mcp 3.2.1's client).
KINDS = {
    "pass": {
        "label": "game pass",
        "collection": f"game-passes/v1/universes/{UNIVERSE_ID}/game-passes",
        "list_field": "gamePasses",
        "id_field": "gamePassId",
        "icon_field": "iconAssetId",
        "scopes": ("game-pass:read", "game-pass:write"),
        "luau_block": "Passes",
    },
    "product": {
        "label": "developer product",
        "collection": f"developer-products/v2/universes/{UNIVERSE_ID}/developer-products",
        "list_field": "developerProducts",
        "id_field": "productId",
        "icon_field": "iconImageAssetId",
        "scopes": ("developer-product:read", "developer-product:write"),
        "luau_block": "Products",
    },
}
PATH = re.compile(
    rf"(game-passes/v1/universes/{UNIVERSE_ID}/game-passes|developer-products/v2/universes/{UNIVERSE_ID}/developer-products)"
    r"(/[1-9][0-9]{0,18})?(/creator)?\Z"
)
KEY = re.compile(r"[A-Za-z][A-Za-z0-9]{0,40}\Z")


class PublishError(Exception):
    """A sanitised, user-facing failure (never contains keys or request bodies)."""


# =============================================================================================
# Helpers: sibling tooling, state
# =============================================================================================


def load_module(name: str, path: Path):
    """Loads one of our own tool modules by path (icons.py for icon aliases, opencloud.py for keys)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise PublishError(f"cannot load {path.name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def opencloud():
    """tools/ui/icons/opencloud.py (key discovery + TLS / no-redirect helpers)."""
    return load_module("sn_opencloud", ROOT / "tools/ui/icons/opencloud.py")


def icons_module():
    """tools/ui/icons/icons.py (ICONS, ALIASES, lower_map: the same resolution IconAssets.get uses)."""
    return load_module("sn_icons", ROOT / "tools/ui/icons/icons.py")


def read_state() -> dict:
    """state.json ({"items": {"pass:VIP": {...}}}); a regular file or absent."""
    if not STATE.exists():
        return {"universeId": UNIVERSE_ID, "items": {}}
    if STATE.is_symlink() or not STATE.is_file():
        raise PublishError("state.json must be a regular file")
    try:
        value = json.loads(STATE.read_text(encoding="utf-8"))
    except ValueError:
        raise PublishError("state.json is not valid JSON") from None
    if not isinstance(value, dict) or value.get("universeId") != UNIVERSE_ID or not isinstance(value.get("items"), dict):
        raise PublishError("state.json belongs to another universe or is malformed")
    return value


def write_text_atomic(path: Path, text: str) -> None:
    """fsynced temp file + rename: a crash never leaves a half-written file."""
    fd, temporary = tempfile.mkstemp(prefix=".publish-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def save_state(state: dict) -> None:
    """Persists state.json deterministically."""
    write_text_atomic(STATE, json.dumps(state, indent=2, sort_keys=True) + "\n")


# =============================================================================================
# Catalogue (from the shipped MonetizationConfig via Lune)
# =============================================================================================


def lune_binary() -> str:
    """The aftman-pinned lune (never a PATH lookup of an arbitrary binary first)."""
    for candidate in (Path.home() / ".aftman/bin/lune",):
        if candidate.is_file():
            return str(candidate)
    found = subprocess.run(["/usr/bin/which", "lune"], capture_output=True, text=True).stdout.strip()
    if not found:
        raise PublishError("lune not found (aftman install)")
    return found


def resolve_icon(key: str, icon: str) -> str:
    """
    The assets/icons key for a pass / product: its own key when an icon exists for it (VIP,
    TripleHatch, ...), else the IconAssets alias of its key (DoubleCash -> x2Cash), else its
    MonetizationConfig `icon` name resolved like IconAssets.get (crown -> VIP, crate -> Crate).
    """
    icons = icons_module()
    if key in icons.ICONS:
        return key
    if key in icons.ALIASES:
        return icons.ALIASES[key]
    resolved = icons.ALIASES.get(icon) or icons.lower_map().get(icon.lower())
    if resolved is None:
        raise PublishError(f"{key}: no icon for {icon!r}")
    return resolved


def catalogue() -> list[dict]:
    """Every pass / product: kind, key, name, description, price, icon key + PNG sha256."""
    result = subprocess.run([lune_binary(), "run", str(DUMP_SCRIPT)], cwd=ROOT, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise PublishError("dump_catalogue.luau failed: " + result.stderr.strip()[-300:])
    data = json.loads(result.stdout.strip().splitlines()[-1])
    items = []
    for kind, rows in (("pass", data["passes"]), ("product", data["products"])):
        for row in rows:
            key = row["key"]
            if not KEY.fullmatch(key):
                raise PublishError(f"bad key {key!r}")
            name, description, price = row["name"], row["description"], row["price"]
            if not isinstance(name, str) or not 1 <= len(name) <= 50:
                raise PublishError(f"{key}: name must be 1..50 characters")
            if not isinstance(description, str) or not 1 <= len(description) <= 1000:
                raise PublishError(f"{key}: description must be 1..1000 characters")
            if type(price) is not int or not 1 <= price <= 1_000_000:
                raise PublishError(f"{key}: price must be a whole number of Robux")
            icon = resolve_icon(key, row["icon"])
            path = ICON_DIR / f"{icon}.png"
            data_bytes = path.read_bytes()
            if not data_bytes.startswith(b"\x89PNG\r\n\x1a\n") or len(data_bytes) > MAX_ICON_BYTES:
                raise PublishError(f"{key}: icon {icon}.png is not a PNG within the size limit")
            items.append(
                {
                    "kind": kind,
                    "key": key,
                    "id_key": f"{kind}:{key}",
                    "name": name,
                    "description": description,
                    "price": price,
                    "icon": icon,
                    "iconSha256": hashlib.sha256(data_bytes).hexdigest(),
                    "order": row.get("order", 0),
                    "category": row.get("kind") or "Pass",
                }
            )
    names = [(item["kind"], item["name"]) for item in items]
    if len(set(names)) != len(names):
        raise PublishError("two items of one kind share a name (names are the duplicate guard)")
    return items


# =============================================================================================
# Transport
# =============================================================================================


class Client:
    """Fixed-host Open Cloud client limited to pass / product paths of UNIVERSE_ID."""

    def __init__(self, key: str, timeout: float = 30.0):
        """No proxies, no redirects, verified TLS (helpers shared with the icon uploader)."""
        cloud = opencloud()
        self._key = key
        self.timeout = timeout
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            cloud._NoRedirect(),
            urllib.request.HTTPSHandler(context=cloud._tls_context()),
        )

    def call(self, method: str, path: str, params: dict | None = None, body: bytes | None = None, content_type: str | None = None):
        """
        One request; returns (status, parsed JSON or None). HTTP errors raise PublishError with
        the status + Roblox's short error code / message (never our request data or the key).
        """
        if method not in ("GET", "POST", "PATCH") or not PATH.fullmatch(path):
            raise PublishError("rejected an unexpected Open Cloud path")
        url = BASE_URL + path
        if params:
            url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        headers = {"x-api-key": self._key, "Accept": "application/json"}
        if content_type:
            headers["Content-Type"] = content_type
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                status = response.status
                raw = response.read(MAX_RESPONSE + 1)
        except urllib.error.HTTPError as error:
            status = error.code
            detail = summarise_error(error.read(4096))
            error.close()
            raise HttpFailure(status, detail) from None
        except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException):
            raise PublishError("Open Cloud request failed (network); details omitted") from None
        if len(raw) > MAX_RESPONSE:
            raise PublishError("Open Cloud response exceeded the size limit")
        if not raw.strip():
            return status, None
        try:
            return status, json.loads(raw)
        except ValueError:
            raise PublishError("Open Cloud returned invalid JSON") from None


class HttpFailure(PublishError):
    """An HTTP error status from Open Cloud (status + a short sanitised reason)."""

    def __init__(self, status: int, detail: str):
        super().__init__(f"HTTP {status}{': ' + detail if detail else ''}")
        self.status = status


def summarise_error(raw: bytes) -> str:
    """Roblox's short error code / message only (letters, digits, basic punctuation, <=160 chars)."""
    try:
        parsed = json.loads(raw)
    except ValueError:
        return ""
    parts = []
    if isinstance(parsed, dict):
        for field in ("errorCode", "code", "message", "detail", "errorMessage", "field"):
            value = parsed.get(field)
            if isinstance(value, (str, int)):
                parts.append(re.sub(r"[^A-Za-z0-9 _.,:;()'/-]", "", str(value))[:120])
    return " / ".join(parts)[:160]


def multipart(fields: dict, icon: tuple[str, bytes] | None) -> tuple[bytes, str]:
    """multipart/form-data body (text fields + optional imageFile PNG) and its content type."""
    boundary = "SellNukesMonetization" + uuid.uuid4().hex
    body = b""
    for name, value in fields.items():
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode() + str(value).encode() + b"\r\n"
    if icon is not None:
        file_name, data = icon
        body += (
            f'--{boundary}\r\nContent-Disposition: form-data; name="imageFile"; filename="{file_name}"\r\n'
            "Content-Type: image/png\r\n\r\n"
        ).encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return body, "multipart/form-data; boundary=" + boundary


def normalise(kind: str, row: dict) -> dict:
    """A remote item as {id, name, description, price, forSale, iconAssetId}."""
    api = KINDS[kind]
    raw_id = row.get(api["id_field"])
    try:
        item_id = int(raw_id)
    except (TypeError, ValueError):
        raise PublishError(f"Open Cloud returned a {api['label']} without an id") from None
    price = (row.get("priceInformation") or {}).get("defaultPriceInRobux")
    icon = row.get(api["icon_field"])
    return {
        "id": item_id,
        "name": row.get("name") if isinstance(row.get("name"), str) else "",
        "description": row.get("description") if isinstance(row.get("description"), str) else "",
        "price": price if isinstance(price, int) else None,
        "forSale": row.get("isForSale") is True,
        "iconAssetId": int(icon) if isinstance(icon, (int, str)) and str(icon).isdigit() and int(icon) > 0 else None,
    }


def list_remote(client: Client, kind: str) -> list[dict]:
    """Every existing pass / product of the universe (read-only, paginated, bounded)."""
    api = KINDS[kind]
    items, token = [], None
    for _ in range(MAX_PAGES):
        _, data = client.call("GET", api["collection"] + "/creator", {"pageSize": 50, "pageToken": token})
        rows = (data or {}).get(api["list_field"])
        if not isinstance(rows, list):
            raise PublishError(f"Open Cloud returned a {api['label']} list without {api['list_field']}")
        items += [normalise(kind, row) for row in rows]
        token = (data or {}).get("nextPageToken")
        if not token:
            return items
    raise PublishError("too many pages listing existing items")


def get_remote(client: Client, kind: str, item_id: int) -> dict:
    """One existing item (read-only)."""
    _, data = client.call("GET", f"{KINDS[kind]['collection']}/{item_id}/creator")
    return normalise(kind, data or {})


# =============================================================================================
# probe / plan / publish
# =============================================================================================


def command_probe(_args=None) -> int:
    """Read-only scope probe: GET both list endpoints with each local key; prints labels + status only."""
    rows = []
    for label, key in opencloud().key_candidates():
        client = Client(key, timeout=20)
        result = {"key": label}
        for kind in KINDS:
            try:
                status, _ = client.call("GET", KINDS[kind]["collection"] + "/creator", {"pageSize": 1})
                result[KINDS[kind]["scopes"][0]] = f"OK ({status})"
            except HttpFailure as failure:
                result[KINDS[kind]["scopes"][0]] = f"HTTP {failure.status}"
        rows.append(result)
    for row in rows:
        print("  " + "  ".join(f"{k}={v}" for k, v in row.items()))
    return 0


def pick_client(source: str | None) -> tuple[str, Client]:
    """The first key (or the named source) that can READ both lists for this universe."""
    candidates = opencloud().key_candidates()
    if source:
        candidates = [c for c in candidates if c[0] == source]
        if not candidates:
            raise PublishError(f"no key from source {source!r}")
    for label, key in candidates:
        client = Client(key)
        try:
            for kind in KINDS:
                client.call("GET", KINDS[kind]["collection"] + "/creator", {"pageSize": 1})
        except HttpFailure:
            continue
        return label, client
    raise PublishError(
        "no local key can read this universe's game passes AND developer products. Create an Open Cloud key "
        "(Creator Dashboard > Open Cloud > API Keys) with: game-pass:read, game-pass:write, "
        "developer-product:read, developer-product:write on experience 10773845696, then put it in "
        "~/.config/robeasts/open-cloud.env as ROBLOX_OPEN_CLOUD_KEY=... (chmod 600)"
    )


def diff(item: dict, remote: dict, recorded: dict) -> dict:
    """Fields to PATCH so the remote item matches the catalogue (empty dict = up to date)."""
    changes = {}
    if remote["name"] != item["name"]:
        changes["name"] = item["name"]
    if remote["description"] != item["description"]:
        changes["description"] = item["description"]
    if remote["price"] != item["price"]:
        changes["price"] = item["price"]
    if not remote["forSale"]:
        changes["isForSale"] = "true"
    if recorded.get("iconSha256") != item["iconSha256"] or remote["iconAssetId"] is None:
        changes["imageFile"] = True
    return changes


def build_plan(items: list[dict], remote: dict[str, list[dict]], state: dict) -> list[dict]:
    """
    One action per catalogue item: {"action": "create" | "update" | "ok", "item", "remote",
    "changes"}. Match order: recorded id -> exact name. Raises on a dangling "creating" journal
    entry (unless the item now exists by name).
    """
    plan = []
    for item in items:
        recorded = state["items"].get(item["id_key"], {})
        rows = remote[item["kind"]]
        match = next((r for r in rows if r["id"] == recorded.get("id")), None) if recorded.get("id") else None
        if match is None:
            same_name = [r for r in rows if r["name"] == item["name"]]
            if len(same_name) > 1:
                raise PublishError(f"{item['key']}: {len(same_name)} existing items share the name {item['name']!r}; resolve by hand")
            match = same_name[0] if same_name else None
        if match is None:
            if recorded.get("status") == "creating":
                item["_dangling"] = True
            plan.append({"action": "create", "item": item, "remote": None, "changes": {}})
            continue
        changes = diff(item, match, recorded if recorded.get("id") == match["id"] else {})
        plan.append({"action": "update" if changes else "ok", "item": item, "remote": match, "changes": changes})
    return plan


def print_plan(plan: list[dict]) -> None:
    """One line per item: action, kind, key, price, icon and changed fields."""
    for step in plan:
        item = step["item"]
        extra = ""
        if step["action"] == "update":
            extra = " changes=" + ",".join(step["changes"])
        elif step["action"] == "ok":
            extra = f" id={step['remote']['id']}"
        print(f"  {step['action']:6} {item['kind']:7} {item['key']:13} R${item['price']:<4} icon={item['icon']}{extra}")


def apply(client: Client, step: dict, state: dict, retry_creating: bool) -> None:
    """Executes one create / update; records the result in state.json after every write."""
    item = step["item"]
    api = KINDS[item["kind"]]
    icon_bytes = (ICON_DIR / f"{item['icon']}.png").read_bytes()
    if step["action"] == "create":
        if item.get("_dangling") and not retry_creating:
            raise PublishError(f"{item['key']}: a previous create may have succeeded (journal 'creating'); check the dashboard, then rerun with --retry-creating")
        state["items"][item["id_key"]] = {"status": "creating", "name": item["name"], "kind": item["kind"], "key": item["key"]}
        save_state(state)  # intent persisted BEFORE the POST
        fields = {"name": item["name"], "description": item["description"], "price": item["price"], "isForSale": "true"}
        body, content_type = multipart(fields, (f"{item['key']}.png", icon_bytes))
        for attempt in range(3):
            try:
                _, data = client.call("POST", api["collection"], body=body, content_type=content_type)
                break
            except HttpFailure as failure:
                if failure.status == 429 and attempt < 2:  # rejected before processing: safe to retry
                    time.sleep(5 * (attempt + 1))
                    continue
                raise
        created = normalise(item["kind"], data or {})
        remote = created
        # Some create responses omit price / sale flags: confirm with a read.
        try:
            remote = get_remote(client, item["kind"], created["id"])
        except PublishError:
            pass
        if remote["price"] != item["price"] or not remote["forSale"]:
            fix = {"price": item["price"], "isForSale": "true"}
            body, content_type = multipart(fix, None)
            client.call("PATCH", f"{api['collection']}/{created['id']}", body=body, content_type=content_type)
            remote = get_remote(client, item["kind"], created["id"])
    else:
        fields = {k: v for k, v in step["changes"].items() if k != "imageFile"}
        icon = (f"{item['key']}.png", icon_bytes) if "imageFile" in step["changes"] else None
        body, content_type = multipart(fields, icon)
        client.call("PATCH", f"{api['collection']}/{step['remote']['id']}", body=body, content_type=content_type)
        remote = get_remote(client, item["kind"], step["remote"]["id"])
    state["items"][item["id_key"]] = {
        "status": "live",
        "kind": item["kind"],
        "key": item["key"],
        "id": remote["id"],
        "name": remote["name"],
        "price": remote["price"],
        "forSale": remote["forSale"],
        "icon": item["icon"],
        "iconSha256": item["iconSha256"],
        "iconAssetId": remote["iconAssetId"],
    }
    save_state(state)


def command_publish(args: argparse.Namespace) -> int:
    """plan (+ apply unless --dry-run), then regenerate the ids Luau + docs."""
    items = catalogue()
    state = read_state()
    label, client = pick_client(args.key_source)
    print(f"Key source: {label} (key not shown); universe {UNIVERSE_ID}")
    remote = {kind: list_remote(client, kind) for kind in KINDS}
    print(f"Existing: {len(remote['pass'])} game passes, {len(remote['product'])} developer products")
    plan = build_plan(items, remote, state)
    print_plan(plan)
    todo = [step for step in plan if step["action"] != "ok"]
    if args.dry_run:
        print(f"Dry run: {len(todo)} change(s) planned, nothing written.")
        return 0
    # Adopt already-matching items into state (ids recorded, no write needed).
    for step in plan:
        if step["action"] == "ok":
            recorded = state["items"].get(step["item"]["id_key"], {})
            if recorded.get("id") != step["remote"]["id"]:
                state["items"][step["item"]["id_key"]] = {
                    **recorded,
                    "status": "live",
                    "kind": step["item"]["kind"],
                    "key": step["item"]["key"],
                    "id": step["remote"]["id"],
                    "name": step["remote"]["name"],
                    "price": step["remote"]["price"],
                    "forSale": step["remote"]["forSale"],
                    "icon": step["item"]["icon"],
                    "iconAssetId": step["remote"]["iconAssetId"],
                }
    save_state(state)
    for index, step in enumerate(todo):
        apply(client, step, state, args.retry_creating)
        print(f"  {step['action']}d {step['item']['key']} -> id {state['items'][step['item']['id_key']]['id']}")
        if index + 1 < len(todo):
            time.sleep(1.2)  # stay well under Open Cloud write rate limits
    return command_write()


# =============================================================================================
# write: PublishedProductIds.luau + docs/monetization.md
# =============================================================================================


def recorded_ids(state: dict) -> dict[str, int]:
    """id_key -> live id (only confirmed "live" records)."""
    return {k: v["id"] for k, v in state["items"].items() if v.get("status") == "live" and isinstance(v.get("id"), int)}


def update_ids_luau(ids: dict[str, int]) -> bool:
    """
    Rewrites only the `Key = <id>,` lines inside the Passes / Products blocks of
    PublishedProductIds.luau (shape, order and comments untouched). Every key must already be
    present (MonetizationConfig.validate checks both directions). Returns True when changed.
    """
    text = IDS_LUAU.read_text(encoding="utf-8")
    original = text
    for kind, api in KINDS.items():
        block = re.search(rf"\t{api['luau_block']} = table\.freeze\(\{{\n(.*?)\n\t\}}\),", text, re.S)
        if block is None:
            raise PublishError(f"PublishedProductIds.luau: {api['luau_block']} block not found")
        body = block.group(1)
        new_body = body
        for id_key, item_id in ids.items():
            item_kind, key = id_key.split(":", 1)
            if item_kind != kind:
                continue
            pattern = re.compile(rf"^(\t\t{re.escape(key)} = )\d+,$", re.M)
            if not pattern.search(new_body):
                raise PublishError(f"PublishedProductIds.luau: {key} missing from {api['luau_block']}")
            new_body = pattern.sub(lambda m: f"{m.group(1)}{item_id},", new_body)
        text = text[: block.start(1)] + new_body + text[block.end(1) :]
    if text != original:
        write_text_atomic(IDS_LUAU, text)
        return True
    return False


def write_docs(items: list[dict], state: dict) -> None:
    """docs/monetization.md: the live catalogue table + runbook."""
    ids = recorded_ids(state)
    lines = [
        "# Monetization (live catalogue)",
        "",
        "GENERATED table by `tools/monetization/publish.py` (do not edit the table by hand). Source of",
        "truth for WHAT is sold: `src/shared/Config/MonetizationConfig.luau`; ids:",
        "`src/shared/Config/PublishedProductIds.luau` (0 = not created yet -> the game shows COMING SOON).",
        f"Universe `{UNIVERSE_ID}` (place 132667741281890), owner user 1586034782. Icons: `assets/icons/`.",
        "",
        "| Key | Kind | Name | Price (R$) | Id | Icon |",
        "|-----|------|------|-----------:|----|------|",
    ]
    for item in sorted(items, key=lambda i: (i["kind"] != "pass", i["order"], i["key"])):
        kind = "Game pass" if item["kind"] == "pass" else f"Product ({item['category']})"
        item_id = ids.get(item["id_key"], 0)
        lines.append(f"| {item['key']} | {kind} | {item['name']} | {item['price']} | {item_id or '-'} | `{item['icon']}` |")
    lines += [
        "",
        "## Runbook",
        "",
        "```bash",
        "python3 tools/monetization/publish.py probe        # read-only: which local key can read passes / products",
        "python3 tools/monetization/publish.py plan         # dry run",
        "python3 tools/monetization/publish.py publish      # create missing, patch changed, write ids + this doc",
        "python3 tools/monetization/publish.py status       # catalogue vs recorded ids (offline)",
        "lune run tests/validate.luau && lune run tests/profile-logic.luau",
        "```",
        "",
        "- **Idempotent:** items match by recorded id, else by exact name, so nothing is created twice;",
        "  existing items get a PATCH of only the changed fields (name, description, price, for-sale,",
        "  icon when its PNG changed). Prices / names change in MonetizationConfig, then rerun `publish`.",
        "- **Journal:** `tools/monetization/state.json` records each create intent before the POST and the",
        "  id after. An interrupted create is adopted by name on the next run; if it is still missing,",
        "  `--retry-creating` is required (no blind duplicate).",
        "- **Key + scopes:** an Open Cloud key with `game-pass:read`, `game-pass:write`,",
        "  `developer-product:read`, `developer-product:write`, with experience 10773845696 added, in",
        "  `~/.config/robeasts/open-cloud.env` (`ROBLOX_OPEN_CLOUD_KEY=`, chmod 600) or",
        "  `~/.config/robloxstudio-mcp/open-cloud-key`. Never printed; `probe` shows only source labels.",
        "- Icons follow `IconAssets.get` resolution (product key, its alias, then the config `icon` name).",
        "- **Live prices (managed pricing):** every item uses Roblox managed pricing, so the Price column",
        "  is only the configured FALLBACK. The client shows what Roblox will charge through",
        "  `src/client/UI/PriceBook.luau` (GetProductInfoAsync; 8 in flight, <= 60 calls / min, 5 attempts",
        "  with jittered backoff, refresh every ~10 min; `...` until known; tunables `PriceBookConfig`;",
        "  test `tests/price-book.luau`). UI hooks: `StudUI.robuxTag(price, size, key)`,",
        "  `StudUI.button({ productKey = key })` / `setProductKey`, `StudUI.starburst({ productKey = key })`.",
        "",
    ]
    write_text_atomic(DOCS, "\n".join(lines))


def command_write(_args=None) -> int:
    """Regenerates PublishedProductIds.luau ids (then StyLua) and docs/monetization.md from state."""
    items = catalogue()
    state = read_state()
    ids = recorded_ids(state)
    changed = update_ids_luau(ids)
    stylua = Path.home() / ".aftman/bin/stylua"
    if stylua.is_file():
        subprocess.run([str(stylua), str(IDS_LUAU)], check=True)
    write_docs(items, state)
    print(f"{'Updated' if changed else 'Unchanged'} {IDS_LUAU.relative_to(ROOT)} ({len(ids)} ids); wrote {DOCS.relative_to(ROOT)}")
    return 0


def command_status(_args=None) -> int:
    """Offline: one line per catalogue item with its recorded id and journal status."""
    state = read_state()
    for item in catalogue():
        recorded = state["items"].get(item["id_key"], {})
        print(f"  {item['kind']:7} {item['key']:13} R${item['price']:<4} icon={item['icon']:12} id={recorded.get('id', 0):<14} {recorded.get('status', 'not created')}")
    return 0


def main() -> int:
    """CLI entry (see module docstring)."""
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("probe", help="read-only scope probe of every local key").set_defaults(handler=command_probe)
    plan = commands.add_parser("plan", help="dry run of publish")
    plan.add_argument("--key-source")
    plan.set_defaults(handler=command_publish, dry_run=True, retry_creating=False)
    publish = commands.add_parser("publish", help="create / update everything, then write ids + docs")
    publish.add_argument("--key-source", help="env | robeasts-env | studio-mcp-file")
    publish.add_argument("--dry-run", action="store_true")
    publish.add_argument("--retry-creating", action="store_true")
    publish.set_defaults(handler=command_publish)
    commands.add_parser("status", help="offline catalogue vs recorded ids").set_defaults(handler=command_status)
    commands.add_parser("write", help="regenerate ids Luau + docs from state.json").set_defaults(handler=command_write)
    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PublishError as error:
        sys.exit(f"publish: {error}")
