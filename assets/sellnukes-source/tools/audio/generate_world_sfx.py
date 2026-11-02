#!/usr/bin/env python3
"""
generate_world_sfx.py — synthesise SellNukes' original world sound effects (numpy -> WAV -> MP3).

Why: the LEGO-style build-in and the world FX need toy sounds (brick clacks, sparkle, cash-register
"ka-ching", area-unlock fanfare, a soft whoosh). They are synthesised here from scratch (no samples,
no third-party audio), so they are 100 % original and reproducible.

Sounds (all mono, 44.1 kHz, peak-normalised to -1 dBFS, short fades so nothing clicks):
    clack     0.14 s  two-transient plastic brick snap (band-passed noise + 1.1 kHz body knock)
    whoosh    0.45 s  soft swept-noise air whoosh for parts taking off
    sparkle   0.90 s  rising glassy chime arpeggio with shimmer (build finished)
    kaching   0.75 s  drawer "ka" click + two inharmonic bell partials "ching" (pad purchase)
    pop       0.18 s  rubbery pad-press "boop" (pitch-dropping sine)
    fanfare   1.70 s  bright square-wave arpeggio C-E-G-C' + held chord (area unlocked)

Outputs (assets/audio/world-sfx/): <name>.wav (source), <name>.mp3 (upload), manifest.json
{name: {file, sha256, seconds}}. Upload with tools/audio/upload_world_sfx.py.

Usage:
    python3 tools/audio/generate_world_sfx.py      (needs numpy + LAME `lame` on PATH)
"""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets/audio/world-sfx"
RATE = 44100
RNG_SEED = 20261030  # fixed seed: noise-based sounds are reproducible


def t_axis(seconds: float) -> np.ndarray:
    """Sample times for a sound of the given length."""
    return np.arange(int(seconds * RATE)) / RATE


def env(t: np.ndarray, attack: float, decay: float) -> np.ndarray:
    """Linear attack, exponential decay envelope (decay = time constant in seconds)."""
    a = np.clip(t / max(attack, 1e-4), 0.0, 1.0)
    return a * np.exp(-np.maximum(t - attack, 0.0) / decay)


def bandpass_noise(n: int, low: float, high: float, rng: np.random.Generator) -> np.ndarray:
    """White noise band-limited in the frequency domain (cheap, exact, no scipy needed)."""
    spectrum = np.fft.rfft(rng.standard_normal(n))
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    spectrum[(freqs < low) | (freqs > high)] = 0
    out = np.fft.irfft(spectrum, n)
    return out / (np.abs(out).max() + 1e-9)


def finish(x: np.ndarray) -> np.ndarray:
    """5 ms fades + peak-normalise to -1 dBFS."""
    fade = int(0.005 * RATE)
    x = x.copy()
    x[:fade] *= np.linspace(0, 1, fade)
    x[-fade:] *= np.linspace(1, 0, fade)
    return x / (np.abs(x).max() + 1e-9) * 10 ** (-1 / 20)


def clack(rng):
    t = t_axis(0.14)
    snap = bandpass_noise(len(t), 1800, 7000, rng) * env(t, 0.0005, 0.012)
    second = np.zeros_like(t)
    lag = int(0.028 * RATE)
    second[lag:] = snap[: len(t) - lag] * 0.55
    body = np.sin(2 * np.pi * 1100 * t) * env(t, 0.001, 0.02) * 0.6
    thunk = np.sin(2 * np.pi * 320 * t) * env(t, 0.002, 0.03) * 0.4
    return finish(snap + second + body + thunk)


def whoosh(rng):
    t = t_axis(0.45)
    n = len(t)
    noise = rng.standard_normal(n)
    # Sweep a one-pole low-pass cutoff up then down for the "air passing" shape.
    cutoff = 300 + 2600 * np.sin(np.pi * t / t[-1]) ** 2
    alpha = 1 - np.exp(-2 * np.pi * cutoff / RATE)
    out = np.zeros(n)
    y = 0.0
    for i in range(n):
        y += alpha[i] * (noise[i] - y)
        out[i] = y
    return finish(out * np.sin(np.pi * t / t[-1]) ** 1.5)


def bell(t, freq, decay, partials=((1, 1.0), (2.76, 0.35), (5.4, 0.15))):
    """Glassy bell: inharmonic partials with faster decay for higher partials."""
    out = np.zeros_like(t)
    for ratio, gain in partials:
        out += gain * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t / (decay / ratio**0.5))
    return out


def sparkle(rng):
    t = t_axis(0.9)
    out = np.zeros_like(t)
    notes = (1568, 1976, 2349, 3136, 3951)  # G6 B6 D7 G7 B7: bright major arpeggio
    for i, f in enumerate(notes):
        start = int(i * 0.07 * RATE)
        seg = t[: len(t) - start]
        out[start:] += bell(seg, f, 0.25) * (0.9 - i * 0.08)
    shimmer = bandpass_noise(len(t), 6000, 12000, rng) * env(t, 0.05, 0.25) * 0.08
    return finish(out + shimmer)


def kaching(rng):
    t = t_axis(0.75)
    ka = bandpass_noise(len(t), 900, 5000, rng) * env(t, 0.0005, 0.018)
    drawer = np.sin(2 * np.pi * 180 * t) * env(t, 0.002, 0.04) * 0.5
    start = int(0.07 * RATE)
    ching = np.zeros_like(t)
    seg = t[: len(t) - start]
    ching[start:] = bell(seg, 2637, 0.32, ((1, 1.0), (1.5, 0.6), (2.01, 0.3))) + bell(seg, 3520, 0.22) * 0.5
    return finish(ka * 0.8 + drawer + ching)


def pop(rng):
    t = t_axis(0.18)
    freq = 520 * np.exp(-t / 0.06) + 160
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    return finish(np.sin(phase) * env(t, 0.002, 0.05))


def square(t, freq):
    """Band-limited-ish square (first 7 odd harmonics) — bright toy-trumpet timbre."""
    return sum(np.sin(2 * np.pi * freq * k * t) / k for k in (1, 3, 5, 7))


def fanfare(rng):
    t = t_axis(1.7)
    out = np.zeros_like(t)
    notes = ((523.25, 0.0, 0.16), (659.25, 0.15, 0.16), (783.99, 0.30, 0.16), (1046.5, 0.45, 1.2))
    for freq, start, length in notes:
        s = int(start * RATE)
        seg = t[: min(int(length * RATE), len(t) - s)]
        vib = 1 + 0.004 * np.sin(2 * np.pi * 6 * seg) * (seg > 0.15)
        tone = square(seg, freq * vib) * env(seg, 0.01, 0.45 if length > 1 else 0.12)
        out[s : s + len(seg)] += tone
    # Final held major chord under the top note.
    s = int(0.45 * RATE)
    seg = t[: len(t) - s]
    chord = sum(square(seg, f) for f in (523.25, 659.25, 783.99)) * env(seg, 0.02, 0.5) * 0.35
    out[s:] += chord
    return finish(out)


SOUNDS = {"clack": clack, "whoosh": whoosh, "sparkle": sparkle, "kaching": kaching, "pop": pop, "fanfare": fanfare}


def write_wav(path: Path, samples: np.ndarray) -> None:
    """16-bit PCM mono WAV."""
    data = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(data)


def main() -> None:
    lame = shutil.which("lame")
    if lame is None:
        raise SystemExit("LAME is required (brew install lame)")
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, fn in SOUNDS.items():
        rng = np.random.default_rng(RNG_SEED + len(name))
        samples = fn(rng)
        wav, mp3 = OUT / f"{name}.wav", OUT / f"{name}.mp3"
        write_wav(wav, samples)
        # VBR ~190 kbps, no ID3 tag: no timestamps or tool versions, so re-runs give identical bytes.
        subprocess.run([lame, "--quiet", "-V", "2", "--noreplaygain", "-t", str(wav), str(mp3)], check=True)
        digest = hashlib.sha256(mp3.read_bytes()).hexdigest()
        manifest[name] = {"file": mp3.name, "sha256": digest, "seconds": round(len(samples) / RATE, 3)}
        print(f"[sfx] {name}: {manifest[name]['seconds']} s")
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
