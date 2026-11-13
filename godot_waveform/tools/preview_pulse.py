#!/usr/bin/env python3
"""Renders what the playhead pulse will look like in Godot.

There is no Godot binary in this sandbox, so the pulse is mirrored here with
numpy/PIL, using the same numbers as the toolkit:

* the gradient is the image `WaveformView._draw_pulse()` draws: opaque white at the
  playhead, fading to fully transparent over `pulse_width` pixels (alpha profile
  `(1 - t) ** 1.7`)
* the level comes from `demo.gd::_update_pulse()`: a 30-100 Hz FFT band, mapped to
  dB, normalised against a rolling peak and then run through a transient detector,
  which is what makes it snap on kicks and ignore everything else

Outputs (in preview/):
  preview_pulse.png     - the same playhead position at four pulse levels
  pulse_preview.gif     - a few seconds of the demo track with the pulse live
"""

from __future__ import annotations

import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from preview_render import bake, read_wav, render

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "preview")
SAMPLE = os.path.join(ROOT, "samples", "demo_track.wav")

# view settings (must match the WaveformView defaults)
PULSE_WIDTH_FRACTION = 0.14          # 180 px on a 1280 px wide view
PULSE_COLOR = (1.0, 1.0, 1.0, 0.9)
PULSE_MAX_OPACITY = 0.9
PULSE_EXPONENT = 1.7
PLAYED_TINT = (1.0, 1.0, 1.0, 0.06)
PLAYHEAD_COLOR = (1.0, 1.0, 1.0, 0.9)

# demo.gd kick detector settings
BASS_LO, BASS_HI = 30.0, 100.0
KICK_EMPHASIS = 2.0


def pulse_profile(width, height):
    """Alpha ramp of the gradient image: 1 at the playhead, 0 at the far end."""
    t = np.linspace(0.0, 1.0, width)[None, :]
    alpha = np.power(np.clip(1.0 - t, 0.0, 1.0), PULSE_EXPONENT)
    return np.repeat(alpha, height, axis=0)


def compose(base, play_x, level, width_px):
    """Base waveform + played tint + gradient pulse + playhead line."""
    width, height = base.size
    out = np.asarray(base.convert("RGB"), dtype=np.float32).copy()

    # played part tint
    played = np.array(PLAYED_TINT[:3], dtype=np.float32) * 255.0
    tint = np.array(PLAYED_TINT[3], dtype=np.float32)
    end = int(round(play_x))
    if end > 0:
        out[:, :end, :] = out[:, :end, :] * (1.0 - tint) + played * tint

    # gradient pulse
    if level > 0.002:
        profile = pulse_profile(width_px, height)
        opacity = min(max(level * PULSE_MAX_OPACITY, 0.0), 1.0)
        alpha = profile * PULSE_COLOR[3] * opacity
        colour = np.array(PULSE_COLOR[:3], dtype=np.float32) * 255.0
        x0 = int(round(play_x))
        x1 = min(x0 + width_px, width)
        if x1 > x0:
            a = alpha[:, : x1 - x0][..., None]
            out[:, x0:x1, :] = out[:, x0:x1, :] * (1.0 - a) + colour * a

    frame = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB")
    draw = ImageDraw.Draw(frame, "RGBA")
    head = 2.0 + level * 2.0
    draw.rectangle([play_x - head * 0.5, 0, play_x + head * 0.5, height],
                   fill=(255, 255, 255, int(255 * PLAYHEAD_COLOR[3])))
    return frame


def kick_curve(frames, rate, times):
    """Mirror of demo.gd::_update_pulse(): low band + transient detector."""
    mono = frames.mean(axis=1)
    window = 1024
    raw = []
    for t in times:
        start = int(max(t * rate - window, 0))
        chunk = mono[start:start + window]
        if len(chunk) < window:
            chunk = np.pad(chunk, (0, window - len(chunk)))
        spectrum = np.abs(np.fft.rfft(chunk * np.hanning(len(chunk))))
        freqs = np.fft.rfftfreq(window, 1.0 / rate)
        band = spectrum[(freqs >= BASS_LO) & (freqs <= BASS_HI)]
        magnitude = float(band.mean()) if len(band) else 0.0
        raw.append(max(math.log(max(magnitude, 1e-5)) + 9.2, 0.0) / 5.0)
    raw = np.clip(np.array(raw), 0.0, 1.0)

    delta = 1.0 / 60.0
    peak, slow, level = 0.0, 0.0, 0.0
    out = []
    for value in raw:
        peak = max(value, peak - delta * 0.25)
        reference = max(peak, 0.3)
        normalised = min(value / reference, 1.0)
        slow += (normalised - slow) * min(delta * 2.5, 1.0)
        transient = min(max((normalised - slow) * KICK_EMPHASIS + normalised * 0.35, 0.0), 1.0)
        speed = 0.6 if transient > level else 0.14
        level += (transient - level) * speed
        out.append(level)
    return out


def main() -> None:
    frames, rate = read_wav(SAMPLE)
    env, slots, total = bake(frames)
    duration = len(frames) / rate
    peak = max(float(np.abs(env[k]).max()) for k in ("min_l", "max_l", "min_r", "max_r"))

    # ---- still: one position at four pulse levels -------------------------
    width, height, padding = 900, 200, 8
    base = render(env, slots, width=width, height=height, supersample=2, padding=padding,
                  channel_mode="mix", peak=peak).convert("RGB")
    ratio = 0.42
    strips = []
    labels = ["pulse = 0.00 (silence)", "pulse = 0.35 (soft bass)",
              "pulse = 0.70 (steady kick)", "pulse = 1.00 (hard kick)"]
    for level in (0.0, 0.35, 0.7, 1.0):
        strips.append(compose(base, ratio * width, level, int(width * PULSE_WIDTH_FRACTION)))

    caption_h = 24
    canvas = Image.new("RGB", (width, (height + caption_h) * len(strips)), (12, 14, 19))
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    for i, strip in enumerate(strips):
        y = i * (height + caption_h)
        canvas.paste(strip, (0, y + caption_h))
        draw.text((12, y + 7), labels[i], fill=(150, 158, 175), font=font)
    canvas.save(os.path.join(OUT, "preview_pulse.png"))
    print("wrote preview/preview_pulse.png")

    # ---- animation: real kick energy from the demo track -----------------
    gw, gh, gp = 560, 132, 6
    fps, seconds, start_time = 24, 6.0, 0.4
    times = [start_time + i / fps for i in range(int(fps * seconds))]
    levels = kick_curve(frames, rate, times)

    span_from = start_time / duration
    span_to = (start_time + seconds) / duration
    sub = render(env, slots, width=gw, height=gh, supersample=2, padding=gp,
                 channel_mode="mix", peak=peak,
                 view_start=span_from, view_end=span_to).convert("RGB")

    gif_frames = []
    for t, level in zip(times, levels):
        play = (t / duration - span_from) / (span_to - span_from)
        gif_frames.append(compose(sub, play * gw, level, int(gw * PULSE_WIDTH_FRACTION)))

    quantised = [frame.quantize(colors=64, method=Image.MEDIANCUT) for frame in gif_frames]
    path = os.path.join(OUT, "pulse_preview.gif")
    quantised[0].save(path, save_all=True, append_images=quantised[1:],
                      duration=int(1000 / fps), loop=0, optimize=True)
    print(f"wrote preview/pulse_preview.gif ({len(gif_frames)} frames, "
          f"{os.path.getsize(path) // 1024} KB)")


if __name__ == "__main__":
    main()
