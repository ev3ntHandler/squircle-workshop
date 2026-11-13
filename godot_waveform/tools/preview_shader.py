#!/usr/bin/env python3
"""Renders stills of the shader visualiser without Godot.

This is a numpy port of `shaders/waveform_visualizer.gdshader` (the CC0 "waveforms"
shader) using the parameters the demo passes in, so the README can show what the
bottom-right widget actually looks like at different energy levels.

Output: preview/preview_visualizer.png
"""

from __future__ import annotations

import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "preview")

# uniforms used by the demo / WaveformVisualizer defaults
LINES = 56
AMPLITUDE = 1.0
FREQUENCY = 0.09
INTENSITY = 0.88
LINE_SHARPNESS = 0.5
LINE_SIZE = 0.8
FADE = 0.1
REST_SIZE = -0.2
EDGE = 0.05
SPEED = 0.5
COLOR = (0.42, 0.82, 1.0, 1.0)
SPEECH_INTENSITY = 0.8
IDLE_LEVEL = 0.18


def fract(x):
    return x - np.floor(x)


def random(ux, uy):
    return fract(np.sin(ux * 12.9898 + uy * 78.233) * 43758.5453123)


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / np.where(edge1 == edge0, 1e-9, edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def noise(ux, uy):
    ix, iy = np.floor(ux), np.floor(uy)
    fx, fy = ux - ix, uy - iy
    a = random(ix, iy)
    b = random(ix + 1.0, iy)
    c = random(ix, iy + 1.0)
    d = random(ix + 1.0, iy + 1.0)
    bx = smoothstep(0.0, 1.0, fx)
    by = smoothstep(0.0, 1.0, fy)
    return (a * (1 - bx) + b * bx) + \
           (c - a) * by * (1.0 - bx) + \
           (d - b) * bx * by


def fbm(ux, uy):
    value = np.zeros_like(ux)
    amp, freq = 0.5, 4.0
    for _ in range(4):
        value += amp * noise(freq * ux - 0.5, freq * uy - 0.5)
        amp *= 0.6
        freq *= 2.0
    return value


def render_shader(width, height, time, progress, background=(0.03, 0.04, 0.06)):
    ys, xs = np.mgrid[0:height, 0:width]
    uvx = (xs + 0.5) / width
    uvy = (ys + 0.5) / height

    columns = float(LINES)
    column_index = np.round(uvx * columns) / columns
    cutoff = smoothstep(0.0, EDGE, column_index) * (1.0 - smoothstep(1.0 - EDGE, 1.0, column_index))

    speech = fbm(np.full_like(uvx, 1.0), np.full_like(uvx, time * SPEED * 1.3) * SPEECH_INTENSITY) * 1.5

    value = fbm(np.round(uvx * columns) * FREQUENCY, np.full_like(uvx, time * SPEED)) * speech * progress
    value = value * cutoff

    wave = smoothstep(1.0 - INTENSITY, 1.0, value) * AMPLITUDE
    wave = wave + REST_SIZE * 0.2

    line = np.abs(np.sin(columns * 3.1416 * uvx + 1.5))
    line = smoothstep(1.0 - LINE_SIZE, (1.0 - LINE_SIZE) + (1.0 - LINE_SHARPNESS), line)

    mask = 1.0 - smoothstep(wave, wave + FADE, np.abs(uvy - 0.5) * 2.0)
    line = line * mask

    rgb = line[..., None] * np.array(COLOR[:3], np.float32)
    alpha = line * COLOR[3]
    bg = np.array(background, np.float32)
    out = rgb + (1.0 - alpha[..., None]) * bg
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGB")


def main() -> None:
    panel_w, panel_h = 320, 108
    levels = [(0.0, "energy 0.0 - silence"),
              (0.45, "energy 0.45 - mid"),
              (0.95, "energy 0.95 - kick")]
    scale = 2
    gap = 18
    caption_h = 26
    total_w = (panel_w * scale + gap) * len(levels) + gap
    total_h = panel_h * scale + caption_h + gap
    canvas = Image.new("RGB", (total_w, total_h), (12, 14, 19))
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()

    for i, (energy, label) in enumerate(levels):
        progress = IDLE_LEVEL + (1.0 - IDLE_LEVEL) * energy
        frame = render_shader(panel_w, panel_h, time=2.4 + i * 0.31, progress=progress)
        frame = frame.resize((panel_w * scale, panel_h * scale), Image.LANCZOS)
        x = gap + i * (panel_w * scale + gap)
        y = caption_h
        canvas.paste(frame, (x, y))
        draw.rectangle([x, y, x + panel_w * scale - 1, y + panel_h * scale - 1],
                       outline=(90, 150, 205))
        draw.text((x, 9), label, fill=(150, 158, 175), font=font)

    canvas.save(os.path.join(OUT, "preview_visualizer.png"))
    print("wrote preview/preview_visualizer.png")


if __name__ == "__main__":
    main()
