#!/usr/bin/env python3
"""Python mirror of src/waveform_baker.gd + src/waveform_renderer.gd.

It is NOT part of the Godot project - it exists so the renderer's geometry can be
checked (and previewed) without launching the engine. Keep the math in sync with
the GDScript version if you change it.
"""
import math
import os
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFont

STEP_SIZE = 128


# ----------------------------------------------------------------------------- baking
def read_wav(path):
    with wave.open(path, "rb") as w:
        channels = w.getnchannels()
        rate = w.getframerate()
        width = w.getsampwidth()
        raw = w.readframes(w.getnframes())
    assert width == 2, "preview helper only handles 16-bit PCM"
    pcm = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    return pcm.reshape(-1, channels), rate


def bake(frames, step=STEP_SIZE):
    """Mirrors WaveformBaker._Decoder: min/max/rms per `step` frames, per channel."""
    total = frames.shape[0]
    slots = int(math.ceil(total / step))
    out = {k: np.zeros(slots, np.float32) for k in
           ("min_l", "max_l", "rms_l", "min_r", "max_r", "rms_r")}
    for s in range(slots):
        chunk = frames[s * step:(s + 1) * step]
        left = chunk[:, 0]
        right = chunk[:, 1] if chunk.shape[1] > 1 else chunk[:, 0]
        out["min_l"][s], out["max_l"][s] = left.min(), left.max()
        out["rms_l"][s] = math.sqrt(float(np.mean(left * left)))
        out["min_r"][s], out["max_r"][s] = right.min(), right.max()
        out["rms_r"][s] = math.sqrt(float(np.mean(right * right)))
    return out, slots, total


def bake_window(frames, rate, t0, t1, step=STEP_SIZE):
    """Mirrors WaveformBaker.bake_stream_range(): decode [t0, t1) at `step`."""
    a = int(round(t0 * rate))
    b = int(round(t1 * rate))
    return bake(frames[a:b], step)


def reduce_slots(env, slots, columns, channel="mix", slot_from=-1, slot_to=-1):
    """Mirrors WaveformData.reduce(), including its optional slot window."""
    mins = np.zeros(columns, np.float32)
    maxs = np.zeros(columns, np.float32)
    rms = np.zeros(columns, np.float32)
    if slot_from < 0:
        slot_from = 0
    if slot_to < 0 or slot_to > slots:
        slot_to = slots
    slot_from = min(max(slot_from, 0), slots - 1)
    if slot_to <= slot_from:
        slot_to = min(slot_from + 1, slots)

    per_column = (slot_to - slot_from) / columns
    for c in range(columns):
        a = slot_from + int(c * per_column)
        b = slot_from + int((c + 1) * per_column)
        b = min(max(b, a + 1), slot_to)
        a = min(max(min(a, b - 1), slot_from), slot_to - 1)
        if channel == "mix":
            lo = (env["min_l"][a:b] + env["min_r"][a:b]) * 0.5
            hi = (env["max_l"][a:b] + env["max_r"][a:b]) * 0.5
            sq = (env["rms_l"][a:b] ** 2 + env["rms_r"][a:b] ** 2) * 0.5
        elif channel == "right":
            lo, hi = env["min_r"][a:b], env["max_r"][a:b]
            sq = env["rms_r"][a:b] ** 2
        else:
            lo, hi = env["min_l"][a:b], env["max_l"][a:b]
            sq = env["rms_l"][a:b] ** 2
        mins[c] = lo.min() if len(lo) else 0.0
        maxs[c] = hi.max() if len(hi) else 0.0
        rms[c] = math.sqrt(float(np.mean(sq))) if len(sq) else 0.0
    return mins, maxs, rms


# --------------------------------------------------------------------------- rendering
def _box_blur(values, radius):
    n = len(values)
    out = np.zeros(n, np.float32)
    for i in range(n):
        a = max(i - radius, 0)
        b = min(i + radius, n - 1)
        out[i] = values[a:b + 1].mean()
    return out


def _smooth(values, radius):
    if radius <= 0 or len(values) < 3:
        return values
    return _box_blur(_box_blur(values, radius), radius)


def _colors(a, b, n):
    """n colour stops between a and b, shape (n, 4)."""
    t = np.linspace(0.0, 1.0, max(n, 1))[:, None]
    return np.asarray(a, np.float32) * (1 - t) + np.asarray(b, np.float32) * t


def render(env, slots, *, width=1200, height=256, columns=0, supersample=2, padding=10,
           bar_gap=0, min_bar_height=1,
           background=(0.05, 0.055, 0.07, 1.0), background_bottom=(0.09, 0.10, 0.13, 1.0),
           transparent=False,
           wave_color_top=(0.42, 0.78, 1.0, 1.0), wave_color_bottom=(0.20, 0.42, 0.95, 1.0),
           draw_rms=True, rms_color=(0.88, 0.97, 1.0, 0.55),
           channel_mode="mix", stereo_gap=6, center_line=(1, 1, 1, 0.08),
           normalize=True, gain=1.0, view_start=0.0, view_end=1.0, peak=0.0,
           smoothing=0):
    ss = int(supersample)
    W, H = width * ss, height * ss

    img = np.zeros((H, W, 4), np.float32)
    if not transparent:
        t = np.linspace(0.0, 1.0, H)[:, None]
        img[:] = (np.asarray(background, np.float32) * (1 - t) +
                  np.asarray(background_bottom, np.float32) * t)[:, None, :]

    pad = int(round(padding * ss))
    usable = max(H - pad * 2, 1)

    # ---- visible slot window (zoom) ----
    vs = min(max(view_start, 0.0), 1.0)
    ve = min(max(view_end, 0.0), 1.0)
    if ve <= vs:
        ve = min(vs + 1e-6, 1.0)
    slot_from = min(max(int(np.floor(vs * slots)), 0), slots - 1)
    slot_to = min(max(int(np.ceil(ve * slots)), slot_from + 1), slots)

    stereo = np.any(np.abs(env["min_r"] - env["min_l"]) > 1e-5) or \
             np.any(np.abs(env["max_r"] - env["max_l"]) > 1e-5)
    split = (channel_mode == "stereo") and stereo
    if split:
        gap = int(round(stereo_gap * ss))
        lane_h = max(int((usable - gap) * 0.5), 1)
        lanes = [(pad, lane_h, "left"), (pad + lane_h + gap, lane_h, "right")]
    else:
        lanes = [(pad, usable, channel_mode if channel_mode in ("left", "right") else "mix")]

    g = gain
    if normalize:
        reference = peak
        if reference <= 0.0:
            reference = max(float(np.abs(env["min_l"]).max()), float(np.abs(env["max_l"]).max()))
            if stereo:
                reference = max(reference, float(np.abs(env["min_r"]).max()),
                                float(np.abs(env["max_r"]).max()))
        if reference > 0.0005:
            g *= 1.0 / reference

    gap_px = max(int(round(bar_gap)), 0) * ss
    columns = int(columns) if int(columns) > 0 else (
        max(int(width / (bar_gap + 1)), 1) if int(round(bar_gap)) > 0 else width)
    columns = max(1, min(columns, W))
    col_w = W / columns
    min_bar = max(int(round(min_bar_height * ss)), 1)
    flat = np.allclose(wave_color_top, wave_color_bottom)

    for lane_top, lane_h, channel in lanes:
        lane_center = lane_top + lane_h * 0.5
        half = lane_h * 0.5
        mins, maxs, rms = reduce_slots(env, slots, columns, channel, slot_from, slot_to)
        if smoothing > 0:
            mins = _smooth(mins, smoothing)
            maxs = _smooth(maxs, smoothing)
            rms = _smooth(rms, smoothing)

        row_normal = _colors(wave_color_top, wave_color_bottom, lane_h)
        core_rgb = np.asarray(rms_color[:3], np.float32)
        row_core = row_normal[:, :3] * (1 - rms_color[3]) + core_rgb * rms_color[3]
        row_core = np.concatenate([row_core, np.ones((lane_h, 1), np.float32)], axis=1)

        if center_line[3] > 0 and not transparent:
            row = int(min(max(int(lane_center), 0), H - 1))
            tt = row / max(H - 1, 1)
            bg_row = np.asarray(background, np.float32) * (1 - tt) + \
                     np.asarray(background_bottom, np.float32) * tt
            img[row:row + ss, :, :3] = (bg_row[:3] * (1 - center_line[3]) +
                                        np.asarray(center_line[:3]) * center_line[3])
            img[row:row + ss, :, 3] = 1.0

        for c in range(columns):
            x0 = int(c * col_w)
            x1 = int((c + 1) * col_w)
            if x1 <= x0:
                x1 = x0 + 1
            x0 = min(max(x0, 0), W - 1)
            x1 = min(max(x1 - gap_px, x0 + 1), W)

            hi = float(np.clip(maxs[c] * g, -1, 1))
            lo = float(np.clip(mins[c] * g, -1, 1))
            y_top = int(round(lane_center - hi * half))
            y_bot = int(round(lane_center - lo * half))
            if y_bot - y_top < min_bar:
                middle = int((y_top + y_bot) * 0.5)
                y_top = middle - int(min_bar * 0.5)
                y_bot = y_top + min_bar
            y_top = min(max(y_top, lane_top), lane_top + lane_h - 1)
            y_bot = min(max(y_bot, lane_top), lane_top + lane_h - 1)

            if flat:
                img[y_top:y_bot + 1, x0:x1, :] = row_normal[0][None, None, :]
            else:
                rows = row_normal[y_top - lane_top:y_bot + 1 - lane_top]
                img[y_top:y_bot + 1, x0:x1, :] = rows[:, None, :]

            if draw_rms:
                value = float(np.clip(rms[c] * g, 0, 1))
                if value > 0:
                    ct = min(max(int(round(lane_center - value * half)), y_top), y_bot)
                    cb = min(max(int(round(lane_center + value * half)), y_top), y_bot)
                    if cb >= ct:
                        rows = row_core[ct - lane_top:cb + 1 - lane_top]
                        img[ct:cb + 1, x0:x1, :] = rows[:, None, :]

    out = (np.clip(img, 0, 1) * 255.0).round().astype(np.uint8)
    pil = Image.fromarray(out, "RGBA")
    if ss > 1:
        pil = pil.resize((width, height), Image.LANCZOS)
    return pil


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    wav = os.path.join(here, "samples", "demo_track.wav")
    out_dir = os.path.join(here, "preview")
    os.makedirs(out_dir, exist_ok=True)

    frames, rate = read_wav(wav)
    env, slots, total = bake(frames)
    duration = total / rate
    print(f"{wav}: {duration:.2f}s, {rate} Hz, {frames.shape[1]}ch, {slots} slots")

    render(env, slots, width=1600, height=420, supersample=2, padding=12,
           channel_mode="mix").save(os.path.join(out_dir, "preview_mix.png"))

    render(env, slots, width=1200, height=320, supersample=2, padding=10,
           channel_mode="stereo", stereo_gap=6).save(
        os.path.join(out_dir, "preview_stereo.png"))

    render(env, slots, width=1200, height=240, supersample=2, padding=10,
           bar_gap=2, min_bar_height=2, channel_mode="mix",
           wave_color_top=(1.0, 0.83, 0.35, 1.0),
           wave_color_bottom=(0.93, 0.35, 0.45, 1.0),
           rms_color=(1.0, 0.98, 0.9, 0.45),
           background=(0.10, 0.07, 0.08, 1.0),
           background_bottom=(0.16, 0.10, 0.12, 1.0)).save(
        os.path.join(out_dir, "preview_bars.png"))

    render(env, slots, width=1200, height=200, supersample=2, padding=0,
           transparent=True, draw_rms=False, center_line=(0, 0, 0, 0),
           channel_mode="mix").save(os.path.join(out_dir, "preview_transparent.png"))

    # ---- zoom: full envelope vs re-decoded window -------------------------
    t0, t1 = 3.30, 3.60
    width, height = 1600, 220
    zoom_factor = duration / (t1 - t0)
    v_start, v_end = t0 / duration, t1 / duration

    track_peak = max(float(np.abs(env["min_l"]).max()), float(np.abs(env["max_l"]).max()),
                     float(np.abs(env["min_r"]).max()), float(np.abs(env["max_r"]).max()))
    coarse = render(env, slots, width=width, height=height, supersample=2, padding=8,
                    view_start=v_start, view_end=v_end, channel_mode="mix", peak=track_peak)
    fine_env, fine_slots, _ = bake_window(frames, rate, t0, t1, 8)
    fine = render(fine_env, fine_slots, width=width, height=height, supersample=2,
                  padding=8, channel_mode="mix", peak=track_peak)

    caption = 30
    canvas = Image.new("RGB", (width, caption * 2 + height * 2), (14, 16, 21))
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    canvas.paste(coarse.convert("RGB"), (0, caption))
    canvas.paste(fine.convert("RGB"), (0, caption * 2 + height))
    draw.text((12, 9),
              f"{zoom_factor:.0f}x zoom from the full-file envelope "
              f"({STEP_SIZE} frames/slot): the columns are wider than the data, detail is gone",
              fill=(150, 158, 175), font=font)
    draw.text((12, caption + height + 9),
              f"{zoom_factor:.0f}x zoom after re-decoding the visible window "
              f"(8 frames/slot): real detail, same image size",
              fill=(120, 200, 255), font=font)
    canvas.save(os.path.join(out_dir, "preview_zoom_compare.png"))

    # ---- styling: smoothing + caps ---------------------------------------
    # Drawn from a 0.3 s window re-decoded at 8 frames/slot, so the columns vary
    # smoothly and the cap shape is actually visible (a 1 px bar has no room for
    # rounding - give the renderer fewer, wider bars for this look).
    style_env, style_slots, _ = bake_window(frames, rate, t0, t1, 8)
    panels = [
        ("smoothing = 0 (default, one bar per pixel)",
         dict(columns=1200)),
        ("smoothing = 2",
         dict(columns=1200, smoothing=2)),
        ("smoothing = 4",
         dict(columns=1200, smoothing=4)),
        ("smoothing = 0, 90 bars",
         dict(columns=90, bar_gap=4, min_bar_height=3)),
        ("smoothing = 2, 90 bars",
         dict(columns=90, bar_gap=4, min_bar_height=3, smoothing=2)),
    ]
    pw, ph, caption_h = 1200, 150, 26
    canvas = Image.new("RGB", (pw, (ph + caption_h) * len(panels)), (12, 14, 19))
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    for i, (title, kwargs) in enumerate(panels):
        panel = render(style_env, style_slots, width=pw, height=ph, supersample=2,
                       padding=8, channel_mode="mix", **kwargs)
        y = i * (ph + caption_h)
        canvas.paste(panel.convert("RGB"), (0, y + caption_h))
        draw.text((12, y + 8), title, fill=(150, 158, 175), font=font)
    canvas.save(os.path.join(out_dir, "preview_styles.png"))

    print("previews written to", out_dir)


if __name__ == "__main__":
    main()
