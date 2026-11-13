@tool
class_name WaveformData
extends Resource
## Down‑sampled amplitude envelope of an audio file, plus helpers to turn it into
## column values for drawing.
##
## A [WaveformData] is produced by [WaveformBaker] and consumed by
## [WaveformRenderer] / [WaveformView]. It is a [Resource], so it can be cached
## with [method ResourceSaver.save] and reloaded without decoding the audio again.
##
## Layout: the whole track is split into fixed size slots of [member step_size]
## audio frames. Every slot stores the minimum, maximum and RMS amplitude of the
## left and right channel. Slot `i` covers audio frames
## `[i * step_size, (i + 1) * step_size)` of the stream.
##
## Use [method reduce] to collapse the slots into the exact number of columns you
## want to draw - this is cheap (one pass over the slots, no audio decoding).

## Both channels averaged into one envelope.
const CHANNEL_MIX := -1
## Left channel only.
const CHANNEL_LEFT := 0
## Right channel only (falls back to left when the stream is mono).
const CHANNEL_RIGHT := 1

## Sample rate of the envelope timeline, in frames per second (usually the
## AudioServer mix rate, 44100 by default).
@export var sample_rate: int = 44100
## Number of audio frames covered by one envelope slot.
@export var step_size: int = 128
## 1 for mono sources, 2 for stereo sources.
@export var channels: int = 1
## Exact duration of the decoded audio, in seconds.
@export var duration: float = 0.0
## Total number of audio frames that were decoded.
@export var frame_count: int = 0
## Start time of this envelope inside the audio file, in seconds. This is 0 for
## a normal full-file bake and non-zero for a window baked with
## [method WaveformBaker.bake_stream_range].
@export var window_start: float = 0.0
## Per‑slot minimum amplitude of the left channel, in the -1..1 range.
@export var min_l: PackedFloat32Array = PackedFloat32Array()
## Per‑slot maximum amplitude of the left channel, in the -1..1 range.
@export var max_l: PackedFloat32Array = PackedFloat32Array()
## Per‑slot RMS amplitude of the left channel, in the 0..1 range.
@export var rms_l: PackedFloat32Array = PackedFloat32Array()
## Per‑slot minimum amplitude of the right channel (empty for mono sources).
@export var min_r: PackedFloat32Array = PackedFloat32Array()
## Per‑slot maximum amplitude of the right channel (empty for mono sources).
@export var max_r: PackedFloat32Array = PackedFloat32Array()
## Per‑slot RMS amplitude of the right channel (empty for mono sources).
@export var rms_r: PackedFloat32Array = PackedFloat32Array()


## Column values ready for drawing: one entry per pixel column / bar.
class Columns:
	## Number of columns in this set.
	var count: int = 0
	## Lowest amplitude of each column.
	var min_values: PackedFloat32Array = PackedFloat32Array()
	## Highest amplitude of each column.
	var max_values: PackedFloat32Array = PackedFloat32Array()
	## RMS amplitude of each column - useful for an "inner" brighter core.
	var rms_values: PackedFloat32Array = PackedFloat32Array()


## Returns the number of envelope slots currently stored.
func get_slot_count() -> int:
	return mini(min_l.size(), max_l.size())


## Returns true when the source really had two distinct channels.
func has_stereo() -> bool:
	return channels > 1 and min_r.size() > 0 and min_r.size() == get_slot_count()


## Highest absolute amplitude in the whole file (used for normalisation).
func get_peak() -> float:
	var peak := 0.0
	var slots := get_slot_count()
	for i in slots:
		peak = maxf(peak, absf(min_l[i]))
		peak = maxf(peak, absf(max_l[i]))
		if has_stereo():
			peak = maxf(peak, absf(min_r[i]))
			peak = maxf(peak, absf(max_r[i]))
	return peak


## Highest absolute amplitude per channel: `[left_peak, right_peak]`.
func get_peaks() -> PackedFloat32Array:
	var out := PackedFloat32Array([0.0, 0.0])
	var slots := get_slot_count()
	for i in slots:
		out[0] = maxf(out[0], maxf(absf(min_l[i]), absf(max_l[i])))
		if has_stereo():
			out[1] = maxf(out[1], maxf(absf(min_r[i]), absf(max_r[i])))
		else:
			out[1] = out[0]
	return out


## Amplitude (0..1, mix of both channels) at a given time in seconds.
## Handy for animating a "reactive" version of the waveform while audio plays.
func get_amplitude_at_time(time: float) -> float:
	var slots := get_slot_count()
	if slots == 0 or duration <= 0.0:
		return 0.0
	var slot := clampi(int(time / duration * slots), 0, slots - 1)
	var value := maxf(absf(min_l[slot]), absf(max_l[slot]))
	if has_stereo():
		value = maxf(value, maxf(absf(min_r[slot]), absf(max_r[slot])))
	return value


## Returns the end time of this envelope inside the audio file, in seconds.
func get_window_end() -> float:
	return window_start + duration


## Returns the slot index that contains [param time] (seconds inside the file).
func get_slot_at_time(time: float) -> int:
	var slots := get_slot_count()
	if slots == 0 or duration <= 0.0:
		return 0
	var local := clampf((time - window_start) / duration, 0.0, 0.999999)
	return clampi(int(local * slots), 0, slots - 1)


## Returns the time in seconds covered by one envelope slot.
func get_slot_duration() -> float:
	if sample_rate <= 0:
		return 0.0
	return float(step_size) / float(sample_rate)


## Collapses the envelope into [param column_count] columns.
##
## [param channel] is one of [constant CHANNEL_MIX], [constant CHANNEL_LEFT] or
## [constant CHANNEL_RIGHT]. The cost is linear in the number of slots, so you can
## call this every time the view is resized.
##
## [param slot_from] and [param slot_to] restrict the reduction to a slice of the
## envelope - that is how zooming works: the same envelope is spread over more
## columns, so every column holds fewer audio frames. Pass -1 for "the whole
## envelope".
func reduce(column_count: int, channel: int = CHANNEL_MIX, slot_from: int = -1, slot_to: int = -1) -> Columns:
	var cols := Columns.new()
	column_count = maxi(column_count, 1)
	cols.count = column_count
	cols.min_values.resize(column_count)
	cols.max_values.resize(column_count)
	cols.rms_values.resize(column_count)

	var slots := get_slot_count()
	if slots == 0:
		cols.min_values.fill(0.0)
		cols.max_values.fill(0.0)
		cols.rms_values.fill(0.0)
		return cols

	# clamp the requested slot window
	if slot_from < 0:
		slot_from = 0
	if slot_to < 0 or slot_to > slots:
		slot_to = slots
	slot_from = clampi(slot_from, 0, slots - 1)
	if slot_to <= slot_from:
		slot_to = mini(slot_from + 1, slots)

	var stereo := has_stereo()
	if channel == CHANNEL_RIGHT and not stereo:
		channel = CHANNEL_LEFT

	var use_right := stereo and channel == CHANNEL_RIGHT
	var combine := stereo and channel == CHANNEL_MIX

	var slots_per_column := float(slot_to - slot_from) / float(column_count)
	for c in column_count:
		var from_slot := slot_from + int(c * slots_per_column)
		var to_slot := slot_from + int((c + 1) * slots_per_column)
		to_slot = clampi(to_slot, from_slot + 1, slot_to)
		from_slot = clampi(mini(from_slot, to_slot - 1), slot_from, slot_to - 1)

		var lo := 1.0
		var hi := -1.0
		var sum_of_squares := 0.0
		for i in range(from_slot, to_slot):
			if combine:
				lo = minf(lo, (min_l[i] + min_r[i]) * 0.5)
				hi = maxf(hi, (max_l[i] + max_r[i]) * 0.5)
				sum_of_squares += (rms_l[i] * rms_l[i] + rms_r[i] * rms_r[i]) * 0.5
			elif use_right:
				lo = minf(lo, min_r[i])
				hi = maxf(hi, max_r[i])
				sum_of_squares += rms_r[i] * rms_r[i]
			else:
				lo = minf(lo, min_l[i])
				hi = maxf(hi, max_l[i])
				sum_of_squares += rms_l[i] * rms_l[i]
		cols.min_values[c] = lo if lo <= hi else 0.0
		cols.max_values[c] = hi if lo <= hi else 0.0
		cols.rms_values[c] = sqrt(sum_of_squares / float(to_slot - from_slot))
	return cols


## Short human readable summary, useful for debug output.
func describe() -> String:
	var scope := "%.2fs" % duration
	if window_start > 0.0:
		scope = "%.2fs @ %.2fs" % [duration, window_start]
	return "WaveformData(%d Hz, %s, %s, %d slots, step %d)" % [
		sample_rate,
		"stereo" if has_stereo() else "mono",
		scope,
		get_slot_count(),
		step_size,
	]
