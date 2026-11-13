@tool
class_name WaveformPyramid
extends Resource
## The whole waveform, decoded once and stored at several resolutions.
##
## A [WaveformPyramid] is what makes zooming and seeking in [WaveformView] free:
## the audio is decoded **once** at a fine step, the coarser levels are derived
## from that fine level by a cheap reduction (no audio decoding at all), and the
## whole thing is cached on disk as a single resource. After the first load the
## view just picks a level and draws - no re-decoding when you zoom, pan or seek,
## and no visible jump in quality, because every level holds at least one slot per
## pixel column.
##
## [codeblock]
## var baker := WaveformBaker.new()
## var fine := await baker.bake_file("res://music/song.ogg")   # step 8..16
## var pyramid := WaveformPyramid.build(fine)                   # + levels 32, 64, 128...
## var level := pyramid.pick(1200, 0.25)                        # best level for 4x zoom
## [/codeblock]
##
## Levels are ordered **fine → coarse**: `levels[0]` has the smallest
## [member WaveformData.step_size] and the most slots, the last one is the whole
## track collapsed into a few hundred slots. All levels share the same
## [member duration], [member sample_rate] and peak amplitude, so switching between
## them never changes the vertical scale.

## Bumped when the layout or the level building changes, so stale cache files are
## ignored instead of being read back with the wrong meaning.
const CACHE_VERSION := 1

## How the envelope was produced, e.g. `res://music/song.ogg` or `stream`.
@export var source: String = ""
## Envelope levels, finest first.
@export var levels: Array[WaveformData] = []
## Highest absolute amplitude over the whole track (identical for every level) -
## the normalisation reference that keeps the vertical scale stable.
@export var peak: float = 0.0
## Duration of the source audio, in seconds.
@export var duration: float = 0.0
## Sample rate of the envelope timeline, in frames per second.
@export var sample_rate: int = 44100
## 1 for mono, 2 for stereo.
@export var channels: int = 1


## Builds a pyramid from an already decoded (fine) envelope.
##
## Coarser levels are produced by halving the slot count until the level has about
## [param min_slots] slots left - one reduction pass per level, no decoding, so
## building the whole pyramid costs a fraction of the decode itself.
static func build(fine: WaveformData, min_slots: int = 512) -> WaveformPyramid:
	var pyramid := WaveformPyramid.new()
	if fine == null or fine.get_slot_count() == 0:
		return pyramid
	pyramid.levels.append(fine)
	pyramid.peak = fine.get_peak()
	pyramid.duration = fine.duration
	pyramid.sample_rate = fine.sample_rate
	pyramid.channels = fine.channels
	pyramid.source = fine.resource_path

	var current := fine
	while current.get_slot_count() > maxi(min_slots, 8):
		var coarser := _coarsen(current)
		if coarser == null:
			break
		pyramid.levels.append(coarser)
		current = coarser
	return pyramid


## One level coarser: half the slots, double the step. Minimums stay minimums,
## maximums stay maximums and the RMS is recombined from the squares, so a coarse
## level is an exact envelope of the same audio - just measured with a wider ruler.
static func _coarsen(level: WaveformData) -> WaveformData:
	var slots := level.get_slot_count()
	if slots < 2:
		return null
	var coarser := WaveformData.new()
	coarser.sample_rate = level.sample_rate
	coarser.step_size = level.step_size * 2
	coarser.channels = level.channels
	coarser.duration = level.duration
	coarser.frame_count = level.frame_count
	coarser.window_start = level.window_start

	var out_slots := (slots + 1) / 2
	coarser.min_l.resize(out_slots)
	coarser.max_l.resize(out_slots)
	coarser.rms_l.resize(out_slots)
	var stereo := level.has_stereo()
	if stereo:
		coarser.min_r.resize(out_slots)
		coarser.max_r.resize(out_slots)
		coarser.rms_r.resize(out_slots)

	for i in out_slots:
		var a := i * 2
		var b := mini(a + 2, slots)
		coarser.min_l[i] = _min_range(level.min_l, a, b)
		coarser.max_l[i] = _max_range(level.max_l, a, b)
		coarser.rms_l[i] = _rms_range(level.rms_l, a, b)
		if stereo:
			coarser.min_r[i] = _min_range(level.min_r, a, b)
			coarser.max_r[i] = _max_range(level.max_r, a, b)
			coarser.rms_r[i] = _rms_range(level.rms_r, a, b)
	return coarser


static func _min_range(values: PackedFloat32Array, from_index: int, to_index: int) -> float:
	var out := values[from_index]
	for i in range(from_index + 1, to_index):
		out = minf(out, values[i])
	return out


static func _max_range(values: PackedFloat32Array, from_index: int, to_index: int) -> float:
	var out := values[from_index]
	for i in range(from_index + 1, to_index):
		out = maxf(out, values[i])
	return out


static func _rms_range(values: PackedFloat32Array, from_index: int, to_index: int) -> float:
	var total := 0.0
	for i in range(from_index, to_index):
		total += values[i] * values[i]
	return sqrt(total / float(maxi(to_index - from_index, 1)))


## Number of stored levels (1 for a pyramid built from a tiny envelope).
func get_level_count() -> int:
	return levels.size()


## The finest level - the one every other level was derived from.
func get_finest() -> WaveformData:
	return levels[0] if not levels.is_empty() else null


## Highest absolute amplitude of the whole track.
func get_peak() -> float:
	if peak > 0.0:
		return peak
	var finest := get_finest()
	return finest.get_peak() if finest != null else 0.0


## Number of slots of the finest level.
func get_finest_slots() -> int:
	var finest := get_finest()
	return finest.get_slot_count() if finest != null else 0


## Audio frames per slot of the finest level.
func get_finest_step() -> int:
	var finest := get_finest()
	return finest.step_size if finest != null else 0


## Picks the level to draw from.
##
## [param columns] is the pixel width of the target image, [param visible_fraction]
## the part of the track currently on screen (1.0 = the whole track, 0.1 = 10x
## zoom) and [param slots_per_column] how many envelope slots should fall into one
## pixel column. The result is the **coarsest** level that still satisfies that:
## as few slots as possible to keep the reduction cheap, as many as needed to keep
## the picture identical to the finest level (a few slots per column is enough for
## that - column edges land on slot boundaries, so nothing is lost).
func pick(columns: int, visible_fraction: float = 1.0, slots_per_column: float = 4.0) -> WaveformData:
	if levels.is_empty():
		return null
	var needed := float(maxi(columns, 1)) * maxf(slots_per_column, 1.0) \
			/ clampf(visible_fraction, 0.0001, 1.0)
	for i in range(levels.size() - 1, -1, -1):
		if float(levels[i].get_slot_count()) >= needed:
			return levels[i]
	return levels[0]


## Highest zoom (1 = whole track) this pyramid can still draw without blurring:
## one slot per pixel column of the finest level.
func get_max_zoom(columns: int) -> float:
	var slots := get_finest_slots()
	if slots <= 0:
		return 1.0
	return maxf(float(slots) / float(maxi(columns, 1)), 1.0)


## Human readable summary, useful for debug output.
func describe() -> String:
	var steps := PackedStringArray()
	for level in levels:
		steps.append("%d" % level.step_size)
	return "WaveformPyramid(%d levels, step %s, %d slots finest, %.2fs, peak %.3f)" % [
		levels.size(), ", ".join(steps), get_finest_slots(), duration, get_peak(),
	]
