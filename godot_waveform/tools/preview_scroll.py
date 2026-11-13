#!/usr/bin/env python3
"""Mirror of WaveformView's centered-follow scrolling, to compare the old
"re-render every frame" path with the new "slide an overscanned texture" path.

Not part of the Godot project. Run from the project root:

    python3 tools/preview_scroll.py

Writes preview/preview_scroll_compare.gif and prints the measured bar-to-bar
jitter (mean vertical wobble of a column between two frames, in pixels) and the
number of renders needed to scroll for two seconds.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from preview_render import bake, read_wav, reduce_slots  # noqa: E402

WIDTH = 480
HEIGHT = 88
VISIBLE = 0.25           # zoom 4x
FPS = 60.0
FRAMES = 240             # four seconds of scrolling
GIF_FRAMES = 60          # first second, for the side-by-side preview
OVERSCAN = 0.5
FINE_STEP = 128


def load():
    frames, rate = read_wav("samples/demo_track.wav")
    env, slots, _ = bake(frames, FINE_STEP)
    peak = 0.0
    for key in ("min_l", "max_l", "min_r", "max_r"):
        peak = max(peak, float(np.abs(env[key]).max()))
    return env, slots, peak


def columns_for(env, slots, start, span):
    """Mirrors WaveformRenderer.render() for one lane: slot window -> columns."""
    v0 = min(max(start, 0.0), 1.0)
    v1 = min(max(start + span, 0.0), 1.0)
    slot_from = min(max(int(math.floor(v0 * slots)), 0), slots - 1)
    slot_to = min(max(int(math.ceil(v1 * slots)), slot_from + 1), slots)
    mins, maxs, _ = reduce_slots(env, slots, WIDTH, "mix", slot_from, slot_to)
    return mins, maxs


def columns_wide(env, slots, start, span, columns):
    v0 = min(max(start, 0.0), 1.0)
    v1 = min(max(start + span, 0.0), 1.0)
    slot_from = min(max(int(math.floor(v0 * slots)), 0), slots - 1)
    slot_to = min(max(int(math.ceil(v1 * slots)), slot_from + 1), slots)
    mins, maxs, _ = reduce_slots(env, slots, columns, "mix", slot_from, slot_to)
    return mins, maxs


def tops(mins, maxs, peak):
    gain = 1.0 / peak if peak > 0 else 1.0
    half = (HEIGHT - 8) * 0.5
    center = HEIGHT * 0.5
    return np.round(center - maxs * gain * half).astype(np.int32)


def snap_to_slot(slots, start):
    return math.floor(max(0.0, min(start, 1.0)) * slots) / float(slots)


def run_old(env, slots, peak, ratios):
    """One full rebin per frame (what the view did before)."""
    tops_per_frame = []
    for p in ratios:
        start = min(max(p - VISIBLE * 0.5, 0.0), 1.0 - VISIBLE)
        mins, maxs = columns_for(env, slots, start, VISIBLE)
        tops_per_frame.append(tops(mins, maxs, peak))
    return tops_per_frame, len(ratios)


def run_new(env, slots, peak, ratios):
    """Slide an overscanned strip; re-bake only when it runs out."""
    strip_span = VISIBLE * (1.0 + OVERSCAN)
    strip_cols = int(round(strip_span / VISIBLE * WIDTH))
    view_px = int(round(strip_cols * VISIBLE / strip_span))

    render_start = snap_to_slot(slots, min(max(ratios[0] - VISIBLE * 0.5, 0.0), 1.0 - VISIBLE))
    mins, maxs = columns_wide(env, slots, render_start, strip_span, strip_cols)
    strip_tops = tops(mins, maxs, peak)
    shift = 0
    renders = 1
    tops_per_frame = []
    for p in ratios:
        start = min(max(p - VISIBLE * 0.5, 0.0), 1.0 - VISIBLE)
        want = int(round((start - render_start) / strip_span * strip_cols))
        if want < 0 or want + view_px > strip_cols:
            render_start = snap_to_slot(slots, start)
            mins, maxs = columns_wide(env, slots, render_start, strip_span, strip_cols)
            strip_tops = tops(mins, maxs, peak)
            renders += 1
            want = int(round((start - render_start) / strip_span * strip_cols))
        shift = max(want, 0)
        tops_per_frame.append(strip_tops[shift:shift + WIDTH].copy())
    return tops_per_frame, renders


def boil(tops_per_frame, shifts):
    """Mean/max vertical wobble of a column that should have moved `shift` px.

    Comparing a column against the same piece of audio one frame later is the only
    fair way to measure jitter: the waveform is supposed to move horizontally.
    """
    means, worst = [], 0.0
    for a, b, s in zip(tops_per_frame[:-1], tops_per_frame[1:], shifts):
        d = np.abs(a[8 + s:-8 + s] - b[8:-8])
        means.append(float(d.mean()))
        worst = max(worst, float(np.nanmax(d)))
    return float(np.mean(means)), worst


def draw(tops, label):
    img = Image.new("RGB", (WIDTH, HEIGHT), (16, 18, 24))
    d = ImageDraw.Draw(img)
    for c in range(WIDTH):
        y = int(tops[c])
        y = min(max(y, 0), HEIGHT - 1)
        d.line([(c, y), (c, HEIGHT - 1 - y)], fill=(90, 170, 245))
    # playhead pinned in the middle
    d.line([(WIDTH // 2, 0), (WIDTH // 2, HEIGHT)], fill=(255, 255, 255))
    d.text((6, 4), label, fill=(190, 200, 215))
    return img


def main():
    env, slots, peak = load()
    duration = 8.0
    ratios = [0.20 + (i / FPS) / duration for i in range(FRAMES)]

    old_tops, old_renders = run_old(env, slots, peak, ratios)
    new_tops, new_renders = run_new(env, slots, peak, ratios)

    shifts = [int(round((b - a) / VISIBLE * WIDTH)) for a, b in zip(ratios[:-1], ratios[1:])]
    old_mean, old_max = boil(old_tops, shifts)
    new_mean, new_max = boil(new_tops, shifts)

    print("scrolling %.1fs at 60 fps, view %dx%d, zoom %.0fx" % (
        FRAMES / FPS, WIDTH, HEIGHT, 1.0 / VISIBLE))
    print("%-22s %10s %10s %10s" % ("", "renders", "mean jitter", "max jitter"))
    print("%-22s %10d %9.2fpx %9.2fpx" % ("re-render per frame", old_renders, old_mean, old_max))
    print("%-22s %10d %9.2fpx %9.2fpx" % ("overscan slide", new_renders, new_mean, new_max))
    print("refills: %d renders over %d frames (%.1f per second)" % (
        new_renders, len(ratios), new_renders / (len(ratios) / FPS)))

    panels = []
    for a, b in list(zip(old_tops, new_tops))[:GIF_FRAMES]:
        pair = Image.new("RGB", (WIDTH, HEIGHT * 2 + 6), (40, 42, 48))
        pair.paste(draw(a, "before: re-render every frame"), (0, 0))
        pair.paste(draw(b, "after: texture slide"), (0, HEIGHT + 6))
        panels.append(pair)

    os.makedirs("preview", exist_ok=True)
    panels[0].save("preview/preview_scroll_compare.gif", save_all=True,
                   append_images=panels[1:], duration=int(1000 / 24), loop=0)
    print("wrote preview/preview_scroll_compare.gif")


if __name__ == "__main__":
    main()
