#!/usr/bin/env python3
"""
loading_capture.py — captures the join loading screen (ForgeGUI "SELL NUKES" title + Nukey +
progress bar) on desktop, phone and tablet during one solo playtest, plus a layout probe:
the title / Nukey / progress-bar rects (AbsolutePosition / AbsoluteSize), whether the title's
drawn aspect matches the 1024 x 548 image (no stretch), whether each rect sits fully on screen
(not cut off) and whether the title overlaps Nukey or the bar. Hold the Studio lock.

    STUDIO_LOCK_OWNER=W1b python3 tools/qa/loading_capture.py

Outputs -> docs/verification/world-qa/loading/ (loading-desktop.jpg, loading-phone.jpg,
loading-tablet.jpg, loading.json).
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
import world_tour  # noqa: E402  (require_lock, capture, result, stop_playtest)

OUT = ROOT / "docs/verification/world-qa/loading"
DEVICES = [
    {"label": "phone", "deviceId": "iphone_13", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
]
# Read-only layout probe of the loading screen's images (client runtime; no free-form input).
PROBE = """
local HttpService = game:GetService("HttpService")
local player = game:GetService("Players").LocalPlayer
local screen = workspace.CurrentCamera.ViewportSize
local found = {}
local root = player.PlayerGui:FindFirstChild("SellNukesLoading", true)
if root ~= nil then
    for _, item in root:GetDescendants() do
        local key = ({ Logo = "logo", Nukey = "nukey", Bar = "bar", TipCard = "tip" })[item.Name]
        if key ~= nil and item:IsA("GuiObject") and found[key] == nil then
            found[key] = { pos = { item.AbsolutePosition.X, item.AbsolutePosition.Y },
                size = { item.AbsoluteSize.X, item.AbsoluteSize.Y }, visible = item.Visible,
                scaleType = if item:IsA("ImageLabel") then item.ScaleType.Name else nil,
                loaded = if item:IsA("ImageLabel") then item.IsLoaded else nil,
                image = if item:IsA("ImageLabel") then item.Image else nil }
        end
    end
end
found.screen = { screen.X, screen.Y }
found.loadingActive = player:GetAttribute("LoadingScreenActive")
return HttpService:JSONEncode(found)
"""


def rects_overlap(a: dict, b: dict) -> bool:
    ax, ay = a["pos"]
    aw, ah = a["size"]
    bx, by = b["pos"]
    bw, bh = b["size"]
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


def analyse(probe: dict) -> dict:
    """Stretch / cut-off / overlap verdicts from one probe."""
    result: dict = {}
    sw, sh = probe.get("screen", [0, 0])
    for key in ("logo", "nukey", "bar", "tip"):
        item = probe.get(key)
        if item is None:
            result[key] = "not found"
            continue
        x, y = item["pos"]
        w, h = item["size"]
        result[f"{key}OnScreen"] = x >= -1 and y >= -1 and x + w <= sw + 1 and y + h <= sh + 1
    logo = probe.get("logo")
    if logo is not None:
        w, h = logo["size"]
        # Fit / Crop keep the image aspect inside the label; Stretch only if the label matches it.
        result["logoScaleType"] = logo["scaleType"]
        result["logoLabelAspect"] = round(w / h, 3) if h else None
        result["logoImageAspect"] = round(1024 / 548, 3)
        if probe.get("nukey") is not None:
            result["logoOverlapsNukeyRect"] = rects_overlap(logo, probe["nukey"])
        if probe.get("bar") is not None:
            result["logoOverlapsBarRect"] = rects_overlap(logo, probe["bar"])
        if probe.get("tip") is not None:
            result["logoOverlapsTipRect"] = rects_overlap(logo, probe["tip"])
        result["logoImage"] = logo.get("image")
        result["logoLoaded"] = logo.get("loaded")
    return result


def probe() -> dict:
    raw = world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": PROBE}))
    data = json.loads(raw)
    return {"probe": data, "verdict": analyse(data)}


def main() -> int:
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:100])
    try:
        time.sleep(5)  # the loading screen is up for ~25 s after the client starts
        record["desktop"] = probe()
        world_tour.capture(OUT / "loading-desktop.jpg")
        for device in DEVICES:
            response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
                "entries": [device], "target": "client-1", "format": "jpeg", "quality": 88,
                "settleSeconds": 1.5, "restoreAfter": True,
            }})
            images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
            if images:
                (OUT / f"loading-{device['label']}.jpg").write_bytes(base64.b64decode(images[0]["data"], validate=True))
                record["log"].append(f"{device['label']} captured")
            else:
                record["log"].append(f"{device['label']} failed: {json.dumps(response)[:240]}")
        record["afterDevices"] = probe()
    finally:
        (OUT / "loading.json").write_text(json.dumps(record, indent=2) + "\n")
        world_tour.stop_playtest()
    print(json.dumps({k: v.get("verdict") if isinstance(v, dict) else v for k, v in record.items()}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
