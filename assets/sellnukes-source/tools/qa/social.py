#!/usr/bin/env python3
"""
social.py — Studio QA for the R78 Rush boosts + Friends (R-social: src/server/Services/
{RushService, FriendService}.luau, src/client/Social/SocialClient.luau, the HUD boost chips
src/client/UI/Screens/BoostChips, the Friends window src/client/UI/Screens/Friends and the Welcome
Back comeback banner). One SOLO playtest in the open place (hold the Studio lock; owner R72: never
multiplayer — so a second Roblox friend cannot exist and the friend chip / window are shown with a
display-only Social push; the server-side friend rules are proven in tests/social-logic.luau).

Steps (prints one JSON record; screenshots under docs/verification/r78-social/):
    1. start a solo Play playtest, wait for the HUD, close the boot windows
    2. Rookie Rush: the Studio profile is brand-new -> rookieLeft 900, rushCash 2 online and 1
       offline; the client chip "ROOKIE RUSH 2x mm:ss"; capture desktop / phone / tablet / console
    3. Friend display (fake push) -> "FRIENDS +20%" chip next to it; capture the matrix
    4. Comeback: clear rush, grant a comeback + the join announcement -> rush-only Welcome Back
       (no payout) -> capture; then a payout arrives -> payout window + banner -> capture
    5. Friends window (from the hub source) -> capture; Rewards hub -> capture (Friends tile)
    6. Admin commands through AdminService.dispatchAsync (status, toggle off / on, percent,
       minutes, referral status)
    7. Referral queue end-to-end on the Studio store: enqueue -> consume pays once -> replay pays 0
    8. stop the playtest

Usage:
    python3 scripts/studio-lock.py acquire R-social
    STUDIO_LOCK_OWNER=R-social python3 tools/qa/social.py
    python3 scripts/studio-lock.py release R-social
"""

from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402
import world_tour  # noqa: E402  (require_lock, render, result, stop_playtest)

SERVER = (ROOT / "tools/qa/social_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/social_client.luau").read_text()
SERVER_COMMANDS = {"status", "clear_rush", "grant_rookie", "grant_comeback", "fake_friends", "no_friends",
                   "offline", "admin", "referral"}
CLIENT_COMMANDS = {"diag", "close_all", "open_friends", "open_hub", "text_fit"}
OUT = ROOT / "docs/verification/r78-social"
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def server(command: str, args: list[float] | None = None) -> dict:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return safe_json(world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code})))


def client(command: str, args: list[float] | None = None) -> dict:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return safe_json(world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code})))


def safe_json(raw: str) -> dict:
    try:
        value = json.loads(raw)
        return value if isinstance(value, dict) else {"raw": raw}
    except json.JSONDecodeError:
        return {"raw": raw}


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(DEVICES, images):
        name = f"{prefix}-{device['label']}.jpg"
        (OUT / name).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str(OUT / name))
    if not images:
        names.append("matrix failed: " + json.dumps(response)[:300])
    return names


def wait_until(predicate, seconds: float, every: float = 1.5):
    deadline = time.time() + seconds
    last = None
    while time.time() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except Exception as error:  # VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(every)
    return None


def main() -> int:
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    only = set(sys.argv[1:])
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_until(lambda: client("diag").get("hud") and client("diag"), 150)
        time.sleep(8)  # first profile push + join queue (loading, plot reveal, tutorial card)
        client("close_all")
        time.sleep(1.0)
        # 2. Rookie Rush: the real grant path needs a BRAND-NEW profile, so enter New Player Mode
        #    (a sandbox profile, isNew = true; nothing is saved). The saved Studio profile itself
        #    existed before 0.6.0-style rush data and must NOT get a Rookie Rush.
        record["realProfile"] = server("status")
        record["npmEnter"] = server("admin", [10])
        time.sleep(8)
        client("close_all")
        time.sleep(1.0)
        record["rookie"] = server("status")
        # The sandbox swap replays the join (loading gate, plot reveal): wait for the HUD chips.
        record["rookieClient"] = wait_until(lambda: (lambda d: d if d.get("chips") else None)(client("diag")), 30) \
            or client("diag")
        if not only or "chips" in only:
            record["rookieShots"] = matrix("chips-rookie")
        # 3. Friend display + both chips.
        server("fake_friends")
        time.sleep(1.0)
        record["friendsClient"] = client("diag")
        if not only or "chips" in only:
            record["friendsShots"] = matrix("chips-rookie-friends")
        # 4. Back to the real profile; comeback: rush-only Welcome Back, then a payout arrives.
        record["npmExit"] = server("admin", [11])
        time.sleep(6)
        client("close_all")
        time.sleep(1.0)
        server("clear_rush")
        record["comeback"] = server("grant_comeback", [600, 3 * 86400 + 4 * 3600])
        time.sleep(3.0)
        record["comebackClient"] = client("diag")
        if not only or "welcome" in only:
            record["rushOnlyShots"] = matrix("welcome-rush-only")
        server("offline", [1234567, 3 * 86400 + 4 * 3600])
        time.sleep(1.5)
        record["payoutClient"] = client("diag")
        record["payoutFit"] = client("text_fit")
        if not only or "welcome" in only:
            record["payoutShots"] = matrix("welcome-payout-banner")
        client("close_all")
        time.sleep(1.0)
        # 5. Friends window + the hub tile.
        record["openFriends"] = client("open_friends")
        record["friendsWindow"] = client("diag")
        record["friendsFit"] = client("text_fit")
        if not only or "friends" in only:
            record["friendsShots2"] = matrix("friends-window")
        client("close_all")
        time.sleep(0.6)
        record["openHub"] = client("open_hub")
        time.sleep(0.6)
        record["hubFit"] = client("text_fit")
        if not only or "friends" in only:
            record["hubShots"] = matrix("rewards-hub-friends-tile")
        client("close_all")
        server("no_friends")
        # 6. Admin commands.
        record["admin"] = {}
        for index, label in enumerate(["RushStatus", "RushToggleOff", "RushToggleOn", "FriendPercent20",
                                       "FriendPercent10", "FriendStatus", "ReferralStatus", "RushMinutes20",
                                       "RushMinutes15"], start=1):
            record["admin"][label] = server("admin", [index])
            time.sleep(2.3)  # per-admin command cooldowns (1-2 s)
        # 7. Referral queue on the Studio store.
        record["referral"] = server("referral", [900000 + int(time.time()) % 90000])
    except Exception as error:  # keep the partial record: it is the diagnosis
        record["error"] = repr(error)[:500]
    finally:
        world_tour.stop_playtest()

    rookie = (record.get("rookie") or {}).get("rush") or {}
    online = (record.get("rookie") or {}).get("online") or {}
    offline = (record.get("rookie") or {}).get("offline") or {}
    rookie_chips = [c["text"] for c in (record.get("rookieClient") or {}).get("chips", [])]
    friend_chips = [c["text"] for c in (record.get("friendsClient") or {}).get("chips", [])]
    welcome = (record.get("comebackClient") or {}).get("welcomeText") or []
    payout = (record.get("payoutClient") or {}).get("welcomeText") or []
    admin = record.get("admin") or {}
    referral = record.get("referral") or {}
    after_first = referral.get("afterFirst") or {}
    after_replay = referral.get("afterReplay") or {}
    before = referral.get("before") or {}
    real = (record.get("realProfile") or {}).get("rush") or {}
    checks = {
        "no error": "error" not in record,
        "existing profile never gets a Rookie Rush": real.get("kind") != "rookie",
        "rookie granted (900 s, 2x)": rookie.get("multiplier") == 2 and 800 <= (rookie.get("rookieLeft") or 0) <= 900,
        "rush in online modifiers": online.get("rushCash") == 2,
        "rush NOT in offline modifiers": offline.get("rushCash") == 1,
        "rookie chip shows": any(t.startswith("ROOKIE RUSH 2x") or t.startswith("2x ") for t in rookie_chips),
        # R82: one badge; rookie 2x x friends +20 % reads "2.4x" (a Friend Boost alone reads "+20%").
        "friends chip shows": any("+20%" in t or t.startswith("2.4x") for t in friend_chips),
        "comeback rush-only welcome": any("COMEBACK RUSH" in t for t in welcome) and any("2x CASH" == t for t in welcome),
        "payout window keeps the banner": any("COMEBACK RUSH" in t for t in payout) and any("$" in t for t in payout),
        "friends window opened, invite selected": (record.get("openFriends") or {}).get("open") is True,
        "admin RushStatus ok": ((admin.get("RushStatus") or {}).get("result") or {}).get("ok") is True,
        "admin toggle off neutralises": ((admin.get("RushToggleOff") or {}).get("status") or {}).get("online", {}).get("rushCash") == 1,
        "admin toggle on restores": ((admin.get("RushToggleOn") or {}).get("status") or {}).get("online", {}).get("rushCash") == 2,
        "admin friend percent ok": ((admin.get("FriendPercent20") or {}).get("result") or {}).get("ok") is True,
        "referral paid once": (after_first.get("paid") or 0) == (before.get("paid") or 0) + 1,
        "referral replay pays nothing": (after_replay.get("paid") or 0) == (after_first.get("paid") or 0),
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1, default=str))
    failed = [name for name, ok in checks.items() if not ok]
    print("FAILED: " + ", ".join(failed) if failed else "ALL CHECKS PASSED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
