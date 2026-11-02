#!/usr/bin/env python3
"""
generate_game_sfx.py — synthesise SellNukes' game sound effects (UI, cash, progression, eggs,
crates, cartoon nukes, the Thanksgiving turkey) from scratch: numpy -> WAV -> MP3 (LAME).

Same approach as tools/audio/generate_world_sfx.py (whose helpers it reuses), so every SFX in the
game is original, reproducible (fixed seeds, no tags) and kid-friendly: soft UI clicks, coin tings,
bubbly pops, bright arpeggios, a cartoon "poof" boom (no realistic explosion), a goofy gobble.

Sounds (seconds):
    ui_click .06  ui_hover .05  ui_open .22  ui_close .2  ui_claim .6  ui_locked .26
    cash_small .25  cash_medium .45  cash_big .95
    producer_pop .15  upgrade .5  manager_hired .85
    hatch 1.0  crate_open .8
    nuke_launch 1.2  nuke_whoosh .9  nuke_boom 1.2
    turkey_gobble .85  notification .5
    firework_whistle 1.0 (R71 juice: rising toy-rocket whistle; ForgeGUI takes only ever fell)

Outputs: assets/audio/game-sfx/{<name>.wav, <name>.mp3, manifest.json}; upload with
    python3 tools/audio/upload_sfx.py --set game --user-id 1586034782

Usage:
    python3 tools/audio/generate_game_sfx.py
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import subprocess
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "assets/audio/game-sfx"
SEED = 31102026


def _helpers():
    """Load the world-SFX module by path to reuse its synthesis helpers (env, bell, ...)."""
    spec = importlib.util.spec_from_file_location("world_sfx", HERE / "generate_world_sfx.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


W = _helpers()
RATE = W.RATE
t_axis, env, bell, square, finish, bandpass_noise = W.t_axis, W.env, W.bell, W.square, W.finish, W.bandpass_noise


def sweep(t, f0, f1, curve=1.0):
    """Sine whose frequency glides from f0 to f1 over the clip (phase-integrated, click-free)."""
    frac = (t / t[-1]) ** curve
    freq = f0 + (f1 - f0) * frac
    return np.sin(2 * np.pi * np.cumsum(freq) / RATE)


def place(out, clip, at):
    """Mix `clip` into `out` starting at `at` seconds (clipped to the buffer)."""
    s = int(at * RATE)
    n = min(len(clip), len(out) - s)
    if n > 0:
        out[s : s + n] += clip[:n]
    return out


# --- UI ------------------------------------------------------------------------------------------


def ui_click(rng):
    t = t_axis(0.06)
    tock = sweep(t, 1300, 850, 0.6) * env(t, 0.001, 0.014)
    tick = bandpass_noise(len(t), 3000, 8000, rng) * env(t, 0.0003, 0.003) * 0.35
    return finish(tock + tick)


def ui_hover(rng):
    t = t_axis(0.05)
    return finish(np.sin(2 * np.pi * 1850 * t) * env(t, 0.004, 0.012)) * 0.6


def ui_open(rng):
    t = t_axis(0.22)
    return finish(sweep(t, 480, 980, 0.7) * env(t, 0.006, 0.08) + bell(t, 1960, 0.06) * 0.25)


def ui_close(rng):
    t = t_axis(0.2)
    return finish(sweep(t, 900, 430, 0.8) * env(t, 0.004, 0.07))


def ui_claim(rng):
    t = t_axis(0.6)
    out = np.zeros_like(t)
    for i, f in enumerate((1046.5, 1318.5, 1568.0, 2093.0)):
        place(out, bell(t, f, 0.18) * (1 - i * 0.12), i * 0.055)
    out += bandpass_noise(len(t), 6500, 12000, rng) * env(t, 0.04, 0.15) * 0.06
    return finish(out)


def ui_locked(rng):
    t = t_axis(0.26)
    out = np.zeros_like(t)
    for i, f in enumerate((330, 247)):
        seg = t_axis(0.1)
        place(out, square(seg, f) * env(seg, 0.003, 0.04) * 0.5, i * 0.11)
    return finish(out)


# --- Cash ----------------------------------------------------------------------------------------


def coin(t, f, decay=0.12):
    """A coin 'ting': bright inharmonic bell."""
    return bell(t, f, decay, ((1, 1.0), (2.4, 0.5), (4.1, 0.2)))


def cash_small(rng):
    t = t_axis(0.25)
    return finish(coin(t, 2637, 0.09))


def cash_medium(rng):
    t = t_axis(0.45)
    out = coin(t, 2349, 0.1)
    place(out, coin(t, 3136, 0.12), 0.07)
    return finish(out)


def cash_big(rng):
    t = t_axis(0.95)
    out = bandpass_noise(len(t), 900, 5000, rng) * env(t, 0.0005, 0.015) * 0.7  # register "ka"
    place(out, bell(t, 2637, 0.3, ((1, 1.0), (1.5, 0.6), (2.01, 0.3))), 0.06)  # "ching"
    for i in range(9):  # coin shower
        place(out, coin(t_axis(0.3), rng.uniform(2200, 4200), 0.07) * rng.uniform(0.25, 0.5), 0.15 + i * rng.uniform(0.04, 0.07))
    return finish(out)


# --- Progression ---------------------------------------------------------------------------------


def producer_pop(rng):
    t = t_axis(0.15)
    return finish(sweep(t, 320, 760, 0.5) * env(t, 0.002, 0.04))


def upgrade(rng):
    t = t_axis(0.5)
    out = np.zeros_like(t)
    for i, f in enumerate((523.25, 659.25, 783.99, 1046.5)):
        seg = t_axis(0.16)
        place(out, square(seg, f) * env(seg, 0.004, 0.06) * 0.45, i * 0.065)
    place(out, bell(t_axis(0.3), 2093, 0.12) * 0.4, 0.26)
    return finish(out)


def manager_hired(rng):
    t = t_axis(0.85)
    out = np.zeros_like(t)
    ta = t_axis(0.18)
    place(out, sum(square(ta, f) for f in (392.0, 493.9, 587.3)) * env(ta, 0.01, 0.08) * 0.35, 0.0)  # "ta"
    da = t_axis(0.6)
    place(out, sum(square(da, f) for f in (523.25, 659.25, 783.99, 1046.5)) * env(da, 0.015, 0.3) * 0.3, 0.2)  # "-da!"
    return finish(out)


# --- Eggs, crates --------------------------------------------------------------------------------


def hatch(rng):
    t = t_axis(1.0)
    out = np.zeros_like(t)
    for i, at in enumerate((0.0, 0.16, 0.3)):  # three shell cracks, getting louder
        crack = bandpass_noise(int(0.05 * RATE), 1500, 6000, rng) * env(t_axis(0.05), 0.0004, 0.008)
        place(out, crack * (0.5 + 0.25 * i), at)
    shimmer = sweep(t_axis(0.45), 600, 2400, 0.6) * env(t_axis(0.45), 0.2, 0.15) * 0.4
    place(out, shimmer, 0.38)
    place(out, sweep(t_axis(0.14), 400, 900, 0.5) * env(t_axis(0.14), 0.002, 0.04), 0.8)  # pop!
    place(out, bell(t_axis(0.3), 2093, 0.1) * 0.4, 0.82)
    return finish(out)


def crate_open(rng):
    t = t_axis(0.8)
    out = np.sin(2 * np.pi * 110 * t) * env(t, 0.002, 0.05) * 0.8  # wooden thunk
    out += bandpass_noise(len(t), 200, 1200, rng) * env(t, 0.001, 0.03) * 0.5
    place(out, bandpass_noise(int(0.03 * RATE), 2500, 7000, rng) * env(t_axis(0.03), 0.0003, 0.006) * 0.6, 0.12)  # latch
    for i, f in enumerate((1568.0, 1975.5, 2349.3)):
        place(out, bell(t_axis(0.4), f, 0.15) * 0.4, 0.22 + i * 0.07)
    return finish(out)


# --- Cartoon nukes (kid-friendly: whistles and "poof", never a realistic blast) --------------------


def nuke_launch(rng):
    t = t_axis(1.2)
    n = len(t)
    noise = rng.standard_normal(n)
    cutoff = 200 + 2400 * (t / t[-1]) ** 1.3
    alpha = 1 - np.exp(-2 * np.pi * cutoff / RATE)
    out = np.zeros(n)
    y = 0.0
    for i in range(n):
        y += alpha[i] * (noise[i] - y)
        out[i] = y
    out *= np.clip(t / 0.15, 0, 1) * np.exp(-np.maximum(t - 0.8, 0) / 0.2)
    out += sweep(t, 220, 880, 1.4) * env(t, 0.1, 0.6) * 0.25  # rising cartoon tone
    return finish(out)


def nuke_whoosh(rng):
    t = t_axis(0.9)
    whistle = sweep(t, 2200, 700, 1.2) * env(t, 0.03, 0.6)  # classic falling slide-whistle
    vib = 1 + 0.15 * np.sin(2 * np.pi * 7 * t)
    return finish(whistle * vib)


def nuke_boom(rng):
    t = t_axis(1.2)
    thump = sweep(t, 110, 38, 0.4) * env(t, 0.004, 0.25)
    puff = bandpass_noise(len(t), 80, 900, rng) * env(t, 0.006, 0.22) * 0.6
    out = thump + puff
    for i in range(6):  # confetti "pops" — the boom is a party, not a disaster
        place(out, sweep(t_axis(0.08), 500, 1300, 0.5) * env(t_axis(0.08), 0.002, 0.02) * 0.3, 0.18 + i * 0.07)
    place(out, bell(t_axis(0.5), 1568, 0.15) * 0.3, 0.3)
    return finish(out)


def firework_whistle(rng):
    """R71 juice: a toy firework rocket going UP — a thin whistle gliding up (700 -> 2600 Hz) with a
    light vibrato and a soft high sparkle fizz, swelling in and stopping at the top (the pop is the
    separate ForgeGUI `firework_pop`). Synthesised because three ForgeGUI rounds only ever fell."""
    t = t_axis(1.0)
    vib = 1 + 0.012 * np.sin(2 * np.pi * 9 * t)
    frac = (t / t[-1]) ** 0.85
    freq = (700 + (2600 - 700) * frac) * vib
    whistle = np.sin(2 * np.pi * np.cumsum(freq) / RATE)
    whistle += 0.18 * np.sin(2 * np.pi * np.cumsum(freq * 2) / RATE)  # a little body (2nd harmonic)
    swell = np.clip(t / 0.12, 0, 1) * (0.55 + 0.45 * frac)
    tail = np.clip((t[-1] - t) / 0.06, 0, 1)  # stop right at the top, click-free
    fizz = bandpass_noise(len(t), 3500, 7500, rng) * 0.12 * np.clip(t / 0.05, 0, 1)
    return finish((whistle * 0.55 + fizz) * swell * tail)


# --- Event + notifications -----------------------------------------------------------------------


def turkey_gobble(rng):
    t = t_axis(0.85)
    out = np.zeros_like(t)
    for at, f0 in ((0.0, 430), (0.22, 470), (0.44, 410)):
        seg = t_axis(0.3)
        freq = f0 * (1 + 0.08 * np.sin(2 * np.pi * 3 * seg))
        phase = 2 * np.pi * np.cumsum(freq) / RATE
        saw = 2 * ((phase / (2 * np.pi)) % 1.0) - 1  # buzzy sawtooth voice
        warble = 0.55 + 0.45 * np.sin(2 * np.pi * 21 * seg)  # the "gobble" flutter
        place(out, saw * warble * env(seg, 0.01, 0.12), at)
    return finish(out)


def notification(rng):
    t = t_axis(0.5)
    out = bell(t, 1318.5, 0.16) * 0.9
    place(out, bell(t_axis(0.35), 1046.5, 0.18), 0.13)
    return finish(out)


SOUNDS = {
    "ui_click": ui_click,
    "ui_hover": ui_hover,
    "ui_open": ui_open,
    "ui_close": ui_close,
    "ui_claim": ui_claim,
    "ui_locked": ui_locked,
    "cash_small": cash_small,
    "cash_medium": cash_medium,
    "cash_big": cash_big,
    "producer_pop": producer_pop,
    "upgrade": upgrade,
    "manager_hired": manager_hired,
    "hatch": hatch,
    "crate_open": crate_open,
    "nuke_launch": nuke_launch,
    "nuke_whoosh": nuke_whoosh,
    "nuke_boom": nuke_boom,
    "turkey_gobble": turkey_gobble,
    "notification": notification,
    "firework_whistle": firework_whistle,
}


def main() -> None:
    lame = shutil.which("lame")
    if lame is None:
        raise SystemExit("LAME is required (brew install lame)")
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, fn in SOUNDS.items():
        rng = np.random.default_rng(SEED + sum(map(ord, name)))
        samples = np.asarray(fn(rng), dtype=np.float64)
        wav, mp3 = OUT / f"{name}.wav", OUT / f"{name}.mp3"
        W.write_wav(wav, samples)
        subprocess.run([lame, "--quiet", "-V", "2", "--noreplaygain", "-t", str(wav), str(mp3)], check=True)
        manifest[name] = {
            "file": mp3.name,
            "sha256": hashlib.sha256(mp3.read_bytes()).hexdigest(),
            "seconds": round(len(samples) / RATE, 3),
        }
        print(f"[game-sfx] {name}: {manifest[name]['seconds']} s")
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
