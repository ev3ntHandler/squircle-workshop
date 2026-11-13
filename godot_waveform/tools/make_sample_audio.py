#!/usr/bin/env python3
"""Generates samples/demo_track.wav - a short stereo track used by the demo scene.

Pure numpy synthesis: kick, snare, hats, bass and a wide pad so the rendered
waveform has an interesting, non-uniform envelope.
"""
import os
import struct
import numpy as np

SR = 44100
BPM = 120.0
BEAT = 60.0 / BPM           # 0.5 s
BEATS = 16                  # 8 s
DUR = BEATS * BEAT
N = int(SR * DUR)

t = np.arange(N) / SR
L = np.zeros(N)
R = np.zeros(N)


def add(sig, start, pan=0.0, gain=1.0):
    """Mix a mono signal into the stereo bus at `start` seconds."""
    i0 = int(start * SR)
    i1 = min(N, i0 + len(sig))
    if i1 <= i0:
        return
    s = sig[: i1 - i0] * gain
    # constant-power panning: -1 = hard left, +1 = hard right
    a = (pan + 1.0) * 0.25 * np.pi
    L[i0:i1] += s * np.cos(a) * 1.4142
    R[i0:i1] += s * np.sin(a) * 1.4142


def env(n, attack, decay, curve=2.0):
    a = max(1, int(attack * SR))
    d = max(1, n - a)
    e = np.concatenate([np.linspace(0, 1, a), np.linspace(1, 0, d) ** curve])
    return e[:n]


def kick():
    n = int(0.42 * SR)
    tt = np.arange(n) / SR
    f = 48 + 110 * np.exp(-tt * 26)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR)
    click = np.random.default_rng(1).normal(0, 1, n) * np.exp(-tt * 220) * 0.35
    return (body * np.exp(-tt * 8.5) + click) * 0.9


def snare():
    n = int(0.26 * SR)
    tt = np.arange(n) / SR
    noise = np.random.default_rng(2).normal(0, 1, n)
    body = np.sin(2 * np.pi * 190 * tt) * 0.45
    return (noise * 0.6 + body) * np.exp(-tt * 26) * 0.7


def hat(open_=False):
    n = int((0.14 if open_ else 0.055) * SR)
    tt = np.arange(n) / SR
    # cheap high-passed noise by differencing
    noise = np.random.default_rng(3).normal(0, 1, n)
    noise = np.diff(np.concatenate([[0.0], noise]))
    return noise * np.exp(-tt * (34 if open_ else 95)) * 0.30


def bass(freq, dur):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    sig = np.sin(2 * np.pi * freq * tt) + 0.35 * np.sin(4 * np.pi * freq * tt)
    return sig * env(n, 0.006, dur, 1.6) * 0.55


def pad(freqs, dur):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    sig = np.zeros(n)
    for k, f in enumerate(freqs):
        det = 1.0 + 0.0018 * (k - len(freqs) / 2.0)
        sig += np.sin(2 * np.pi * f * det * tt) + 0.3 * np.sin(2 * np.pi * f * 2 * tt)
    return sig / (len(freqs) * 1.2) * env(n, 0.25, dur, 1.2) * 0.55


CHORDS = {
    "Am": [220.00, 261.63, 329.63],   # A3 C4 E4
    "F": [174.61, 220.00, 261.63],    # F3 A3 C4
    "C": [196.00, 261.63, 329.63],    # G3 C4 E4
    "G": [196.00, 246.94, 293.66],    # G3 B3 D4
}
PROGRESSION = ["Am", "F", "C", "G"]     # one chord per 4 beats (2 s)
BASS_ROOTS = {"Am": 55.0, "F": 43.65, "C": 65.41, "G": 49.0}

for bar in range(4):
    name = PROGRESSION[bar]
    start = bar * 4 * BEAT
    add(pad(CHORDS[name], 4 * BEAT), start, pan=0.0, gain=0.55 if bar else 0.30)

    # bass: root on 1 and 3, octave on the "and" of 3
    add(bass(BASS_ROOTS[name], BEAT * 0.9), start + 0 * BEAT, gain=0.9)
    add(bass(BASS_ROOTS[name], BEAT * 0.9), start + 2 * BEAT, gain=0.75)
    add(bass(BASS_ROOTS[name] * 2, BEAT * 0.45), start + 3.5 * BEAT, gain=0.55)

    # drums
    for b in range(4):
        beat_start = start + b * BEAT
        if bar > 0 or b > 0:
            add(kick(), beat_start, gain=0.95)
        if b in (1, 3) and bar > 0:
            add(snare(), beat_start, pan=0.06, gain=0.85)
        add(hat(), beat_start + BEAT * 0.5, pan=0.45, gain=0.8)
        if bar >= 2:
            add(hat(), beat_start, pan=-0.35, gain=0.55)
    if bar == 3:
        for k in range(4):                     # snare fill on the last bar
            add(snare(), start + 3 * BEAT + k * BEAT * 0.25, pan=0.1, gain=0.55 + 0.1 * k)

# master: gentle fade-in / fade-out, soft clip, normalize to -1 dBFS
fade_in = np.minimum(1.0, t / 0.25)
fade_out = np.minimum(1.0, (DUR - t) / 0.9)
master = fade_in * fade_out
L *= master
R *= master
L = np.tanh(L * 1.1)
R = np.tanh(R * 1.1)
peak = max(np.abs(L).max(), np.abs(R).max())
g = (10 ** (-1.0 / 20.0)) / max(peak, 1e-9)
L *= g
R *= g

stereo = np.stack([L, R], axis=1)
pcm = np.clip(stereo * 32767.0, -32768, 32767).astype("<i2")

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "samples", "demo_track.wav")
os.makedirs(os.path.dirname(out), exist_ok=True)
data = pcm.tobytes()
with open(out, "wb") as f:
    f.write(b"RIFF")
    f.write(struct.pack("<I", 36 + len(data)))
    f.write(b"WAVEfmt ")
    f.write(struct.pack("<IHHIIHH", 16, 1, 2, SR, SR * 2 * 2, 2 * 2, 16))
    f.write(b"data")
    f.write(struct.pack("<I", len(data)))
    f.write(data)

print(f"wrote {out}  ({len(data) / 1024 / 1024:.2f} MB, {DUR:.1f}s, {SR} Hz, stereo 16-bit)")
print(f"peak L={np.abs(L).max():.3f} R={np.abs(R).max():.3f}")
