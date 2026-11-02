#!/usr/bin/env python3
"""
forge_manifest.py — writes manifest.json for the ForgeGUI-made audio sets (was voice_manifest.py).

Sets (each a directory of <key>.mp3 picked from ForgeGUI sound-effect jobs, ElevenLabs
text-to-sound — NOT synthesised here):
    voice  assets/audio/voice-sfx  announcer lines (owner R54). Every take was transcribed locally
           with whisper.cpp (base.en) and only takes that clearly say the intended words were kept
           (a "Knockdown" take that could be heard as a swear word was rejected).
    forge  assets/audio/forge-sfx  world sounds with no synthesised equivalent (owner R56 vehicle
           horn + reversing beep; R71 juice-pass UI / FX / ambience), picked by listening-proxy
           metrics (duration, peak, silence, onsets, pitch track, loudness) and a whisper.cpp
           no-words check. Only combo_tick + lucky_blink + pick_clink (trimmed to the hit) and moon_boing
           (gain) were re-encoded; the rest are byte copies of the ForgeGUI takes.

This script binds each picked MP3 to its sha256 + duration and records where it came from, so
tools/audio/upload_sfx.py uploads the sets like the synthesised ones (hash-bound receipts,
unchanged files never re-upload).

Usage:
    python3 tools/audio/forge_manifest.py                 # rewrite every set's manifest
    python3 tools/audio/upload_sfx.py --user-id 1586034782 --set voice forge

Adding a sound: drop <key>.mp3 into the set's folder, add its provenance to SOURCES, run this,
upload, then add the key to AudioConfig.Sfx (tests/audio checks every configured key has an id).
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SET_DIRS = {
    "voice": ROOT / "assets/audio/voice-sfx",
    "forge": ROOT / "assets/audio/forge-sfx",
}

# set -> key -> (ForgeGUI job id, take index, what it says / sounds like)
VOICE_SOURCES = {
    "vo_three": ("e7636471-6201-4125-9e94-4b7ccda8fa06", 0, "Three!"),
    "vo_two": ("980bbe01-4d34-4faf-b334-a7c0c7b03818", 1, "Two!"),
    "vo_one": ("07b09311-a5c6-4b98-97ad-7583732adc9e", 0, "One!"),
    "vo_launch": ("6a7230fc-5ab1-495e-82be-1ef46b23535f", 0, "Launch!"),
    "vo_direct_hit": ("17efaa14-1586-4cd2-a39b-2aefc332dd2a", 1, "Direct hit!"),
    "vo_intercepted": ("651105f3-b4c6-418e-ba21-9b3e22dc8929", 1, "Intercepted!"),
    "vo_knockdown": ("bdeb90e8-9cf7-4e81-a2b4-d945e3c1a987", 0, "Knocked down!"),
}
FORGE_SOURCES: dict[str, tuple[str, int, str]] = {
    # 2 bursts (measured): "honk-honk"; takes 0/1 had 3 / 1 bursts
    "vehicle_honk": ("44e48e27-d8e8-47ce-b7df-7e470ab27b6a", 2, "cartoon toy truck honk-honk"),
    # 6 evenly spaced 0.1 s tonal beeps (~1.2 kHz); take 0 was one long tone, take 1 irregular
    "vehicle_beep": ("2db6d976-a60b-43c0-a3c7-36af90c8ce6f", 2, "soft toy reversing beeper"),
    # R57 Dino Valley (requested by W9-valley). Every take was also run through whisper.cpp to
    # make sure no words slipped in (a warp take that came back as a scream "AHHH!" was rejected).
    "ptero_squawk_cute": ("6eafae04-d3cb-4259-b0ce-3129deeaaede", 1, "cute baby ptero squeak-squawk"),
    "dino_happy_roar": ("e85eebfb-96b5-4da5-b392-a5b648d08222", 1, "goofy happy dino roar-giggle"),
    "volcano_rumble_soft": ("d9c01cfd-29e1-4a3f-98e8-0df43e9c0071", 0, "soft cartoon volcano rumble + gloop"),
    "warp_whoosh": ("db693e48-5fd1-481c-b01d-02d4111e7236", 0, "swirly time-warp whoosh"),
    "geyser_whoosh": ("fa99b1de-2eb6-4a19-9842-72548cf3d53e", 0, "steamy geyser fizz-whoosh"),
    # R71 juice pass (requested by H1-cashfx). Picked by measurement only (scripted ffprobe/numpy
    # metrics: onsets, note-tracked pitch, envelope, LUFS, band energy) + whisper.cpp base.en on every
    # take: no take produced a real-word transcript. Levels below are integrated LUFS.
    # pop @1.05 kHz + 3 coin clinks (0.13/0.19/0.33 s), done by 0.4 s, -15 LUFS; t2 hissier (>10k 33%)
    "pad_buy": ("d7f03da4-1e18-49d3-8384-64827a4da330", 0, "bubbly pop + small coin jingle"),
    # warm G6+B6 major bell, B6 enters at +40 ms, -19 LUFS; no take has the 3-note arpeggio, t1 = minor
    "milestone": ("f6a720fa-233f-45bb-88c7-b30d7d348025", 2, "warm bell level-up ding"),
    # one 1.2 kHz hit, -52 dB by 90 ms, no provider clipping (t0 had 4 clipped samples, t1 -14 dBFS)
    "combo_tick": ("39ccccdb-ea94-4ba6-8ccb-99448d6a6d30", 2, "click-tick, trimmed 0.14 s + 50 ms fade"),
    # 11 coin onsets in two waves, ends on clinks at 0.94/1.03 s; t1 only 6 onsets ("glass shatters")
    "coin_burst": ("44b99385-c3db-492d-8c87-51c383726455", 0, "cartoon coin shower"),
    # gentle -22 LUFS pop + 16 crackle onsets fizzling out by 1.3 s; t1 a 10 dB louder 0.5 s bang
    "firework_pop": ("53e82dff-ee30-4116-a2ea-da46345025b0", 0, "soft firework poof + crackle"),
    # firework_whistle is NOT here: two ForgeGUI rounds (jobs d90e5e33-..., 7b03876a-...; 5 takes)
    # all FELL in pitch, so it is synthesised (rising 700 -> 2600 Hz) in tools/audio/generate_game_sfx.py.
    # fast rising G-major arpeggio D6/G6 -> B6 (+40 ms) -> D7 (+100 ms); t1 one repeated 1 kHz trill
    "lucky_spawn": ("40de7bbc-8110-493e-bf7f-f1d3f5eea8c9", 2, "sparkly rising ding-ding-ding"),
    # upward G6 -> C7 with re-strikes at 0.17/0.30 s + twinkles >10 kHz; t1 piercing (78% in 2-5 kHz)
    "lucky_claim": ("2788cad0-5f26-45b8-bdfd-a110e08a739f", 0, "bright harp-and-bell reward flourish"),
    # quietest take (-21 LUFS), one rounded 1.6 kHz tick, -57 dB by 90 ms; t1 a 200 ms beep, t2 9 kHz ting
    "lucky_blink": ("cedd76af-d60c-4efa-be4d-845fad8d3424", 0, "countdown tick, trimmed 0.12 s + 50 ms fade"),
    # most wobble (194-501 Hz, 16 modulation onsets) + 0.6 s fade-out; -8.7 LUFS like warp_whoosh
    "ufo_whirr": ("cd47f4d6-c0bd-4dea-bd10-195b44f67df8", 0, "cute warbling saucer whirr"),
    # 4 chirps: bip 2 kHz, rise 1.05->1.7 kHz, blip, fall 2.1->0.55 kHz, clean end by 0.75 s;
    # t1 one long glide, t2 runs to the file end
    "robot_beep": ("24a4dac6-af22-420e-87e0-8f14568319bd", 0, "happy robot beep-boop-bip"),
    # instant hit + 86-113 Hz pitch wobble, gone by 0.5 s; t1 hit lands 55 ms late, t2 "clears throat".
    # All takes were quiet (~-30 LUFS), so re-encoded with volume=12.9dB (128k): peak -14.5 -> -2.1 dBFS
    # (true peak -2.1 dBTP, no clipping), -18 LUFS, envelope unchanged
    "moon_boing": ("72643521-611a-40a9-8438-d6148009e11a", 0, "soft springy moon boing, gain +12.9 dB"),
    # G8 (6.1 kHz) chime with D#8/F#8 glassy partials + swells at 0.14/0.44 s; t1 a pure sine.
    # Both takes are a single note, not "a few notes"
    "star_chime": ("6b1e2b1a-d678-4973-8a21-b8ec3a00a5da", 0, "twinkly glassy star chime"),
    # soft start (-21.5 dB) swelling to -8 dB at 1.2 s with an upward sweep, then fades by 2.4 s;
    # t1 loud from frame 1. Provider clipped 16 samples (7e-5), hidden in the hiss crest
    "rocket_launch_soft": ("d0ec5235-ddd7-4716-a39b-5153adf8ed65", 0, "gentle toy rocket lift-off whoosh"),
    # 30 s loop: 1 s RMS std 0.48 dB (t1 0.93), largest 1 s jump 1.5 dB, loop seam step 0.025 < p99
    # sample step (t1 0.042 > p99.9), last vs first 50 ms 0.2 dB; whisper "(dramatic music)"
    "amb_space": ("73aca092-919a-443a-af01-8899b36468fe", 0, "calm dreamy space ambience loop"),
    # Owner R75 (requested by W7-art34 via H1). One hit, onset 7 ms, 76% of the hit's energy in 2-6 kHz
    # (tonal F7 ~2.8 kHz tink) + most 300-2k "tok" body; -35 dB by 60 ms, no provider clipping.
    # t0 rings at 6.6-9.4 kHz (73% >6k), t1 starts 130 ms late. Re-encoded: attack-aligned + 60 ms fade
    "pick_clink": ("073864a4-5e49-48c7-bc05-4d6368019d8b", 2, "toy pickaxe tok-tink, trimmed 0.17 s + fade"),
}
SOURCES = {"voice": VOICE_SOURCES, "forge": FORGE_SOURCES}


def duration_seconds(path: Path) -> float:
    """Exact decoded duration via ffprobe (rounded to 0.01 s)."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return round(float(out), 2)


def write_set(name: str) -> int:
    """Writes one set's manifest for every SOURCES key whose MP3 exists; returns the line count."""
    folder = SET_DIRS[name]
    manifest = {}
    for key, (job, take, words) in sorted(SOURCES[name].items()):
        path = folder / f"{key}.mp3"
        if not path.is_file():
            print(f"  {name}/{key}: missing {path.name}, skipped")
            continue
        data = path.read_bytes()
        manifest[key] = {
            "file": path.name,
            "seconds": duration_seconds(path),
            "sha256": hashlib.sha256(data).hexdigest(),
            "source": f"forgegui:{job}:{take}",
            "says": words,
        }
    if not manifest:
        return 0
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {len(manifest)} {name} sounds -> {(folder / 'manifest.json').relative_to(ROOT)}")
    return len(manifest)


def main() -> int:
    """Rewrites the manifest of every set that has picked MP3s; returns 0."""
    for name in SOURCES:
        write_set(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
