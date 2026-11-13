@tool
class_name WaveformBaker
extends RefCounted
## Decodes an [AudioStream] (WAV / OGG / MP3) into a [WaveformData] envelope.
##
## Godot does not expose the PCM samples of an OGG or MP3 stream directly, so we
## ask the audio engine to mix it: [method AudioStream.instantiate_playback]
## gives us a real playback object, and
## [method AudioStreamPlayback.mix_audio] renders N frames of it on demand -
## without an [AudioStreamPlayer], without an audio bus and without waiting in
## real time. A 5 minute track is decoded in a fraction of a second.
##
## [b]Basic usage:[/b]
## [codeblock]
## var baker := WaveformBaker.new()
## var data: WaveformData = await baker.bake_file("res://music/song.ogg")
## if data == null:
##     push_error(baker.last_error)
## [/codeblock]
##
## [b]Synchronous usage (editor tools, batch baking):[/b]
## [codeblock]
## var baker := WaveformBaker.new()
## var data := baker.bake_file_sync(path)   # no await
## [/codeblock]
##
## Requires Godot 4.5 or newer (that is when [method AudioStreamPlayback.mix_audio]
## was added to the scripting API).

## Emitted while decoding, `ratio` goes from 0.0 to 1.0.
signal progress_changed(ratio: float)

## One envelope slot per `step_size` audio frames. 128 keeps ~345 slots/second,
## which is far more detail than any waveform view needs while staying small
## (~0.5 MB of RAM per minute of stereo audio).
var step_size: int = 128
## How many frames to ask the mixer for per call. Bigger is faster, smaller keeps
## the main thread more responsive between yields.
var chunk_frames: int = 32768
## Safety net: stop after this many seconds of audio (0 disables the limit).
var max_seconds: float = 1800.0
## How many chunks are decoded between two `await` calls.
var chunks_per_yield: int = 8
## When true, [method bake_stream] yields to the main loop between chunks so the
## UI keeps running. Set to false for a blocking, single shot decode.
var yield_frames: bool = true
## Cache baked envelopes on disk (per file, per [member step_size]).
var use_cache: bool = true
## Where cached [WaveformData] resources are stored.
var cache_dir: String = "user://waveform_cache"

## Human readable reason for the last failure, empty when everything went fine.
var last_error: String = ""


## Loads a stream from [param path].
##
## Works with `res://` resources (the normal imported way) and with absolute
## paths / `user://` at runtime, e.g. a file picked with [FileDialog].
static func load_audio_stream(path: String) -> AudioStream:
	if path.is_empty():
		return null
	var extension := path.get_extension().to_lower()

	if path.begins_with("res://") and ResourceLoader.exists(path):
		var resource := ResourceLoader.load(path)
		if resource is AudioStream:
			return resource as AudioStream

	match extension:
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)

	return null


## Returns true when [param path] looks like an audio file this class can decode.
static func is_supported_file(path: String) -> bool:
	return path.get_extension().to_lower() in ["wav", "ogg", "mp3"]


## Decodes [param path] and returns its envelope, or `null` on failure
## (see [member last_error]). Uses the disk cache when [member use_cache] is on.
func bake_file(path: String) -> WaveformData:
	last_error = ""
	if not is_supported_file(path) and not (path.begins_with("res://") and ResourceLoader.exists(path)):
		last_error = "Unsupported file: %s" % path
		return null

	if use_cache:
		var cached := _load_from_cache(path)
		if cached != null:
			progress_changed.emit(1.0)
			return cached

	var stream := load_audio_stream(path)
	if stream == null:
		last_error = "Could not load an audio stream from %s" % path
		return null

	var data: WaveformData = await bake_stream(stream)
	if data != null and use_cache:
		_save_to_cache(path, data)
	return data


## Blocking variant of [method bake_file] - handy inside editor tools and batch
## scripts where yielding is not possible.
func bake_file_sync(path: String) -> WaveformData:
	last_error = ""
	if use_cache:
		var cached := _load_from_cache(path)
		if cached != null:
			return cached

	var stream := load_audio_stream(path)
	if stream == null:
		last_error = "Could not load an audio stream from %s" % path
		return null

	var data := bake_stream_sync(stream)
	if data != null and use_cache:
		_save_to_cache(path, data)
	return data


## Decodes [param stream] into a [WaveformData], yielding to the main loop between
## chunks so a loading screen / progress bar stays responsive.
func bake_stream(stream: AudioStream) -> WaveformData:
	var decoder := _create_decoder(stream)
	if decoder == null:
		return null

	var budget := maxi(chunks_per_yield, 1)
	while not decoder.step(budget):
		progress_changed.emit(decoder.get_ratio())
		if yield_frames:
			await _next_process_frame()
	progress_changed.emit(1.0)
	return decoder.finish()


## Blocking variant of [method bake_stream].
func bake_stream_sync(stream: AudioStream) -> WaveformData:
	var decoder := _create_decoder(stream)
	if decoder == null:
		return null
	decoder.step(1 << 30)
	progress_changed.emit(1.0)
	return decoder.finish()


## Decodes only a slice of [param stream] at a finer resolution.
##
## This is what makes zooming actually reveal detail: [param start_time] is the
## offset in seconds inside the file, [param window_seconds] the length of the
## slice and [param range_step_size] the number of audio frames per envelope slot
## (smaller = more detail, `1` = one slot per audio frame).
##
## The returned [WaveformData] has [member WaveformData.window_start] set, so
## callers know which part of the track it covers. Range bakes are not cached.
##
## [codeblock]
## var detail: WaveformData = await baker.bake_stream_range(stream, 12.0, 2.0, 8)
## [/codeblock]
func bake_stream_range(stream: AudioStream, start_time: float, window_seconds: float, range_step_size: int = 32) -> WaveformData:
	var decoder := _create_range_decoder(stream, start_time, window_seconds, range_step_size)
	if decoder == null:
		return null

	var budget := maxi(chunks_per_yield, 1)
	while not decoder.step(budget):
		progress_changed.emit(decoder.get_ratio())
		if yield_frames:
			await _next_process_frame()
	progress_changed.emit(1.0)
	return decoder.finish()


## Blocking variant of [method bake_stream_range].
func bake_stream_range_sync(stream: AudioStream, start_time: float, window_seconds: float, range_step_size: int = 32) -> WaveformData:
	var decoder := _create_range_decoder(stream, start_time, window_seconds, range_step_size)
	if decoder == null:
		return null
	decoder.step(1 << 30)
	progress_changed.emit(1.0)
	return decoder.finish()


## Removes every cached envelope.
func clear_cache() -> void:
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)


func _create_decoder(stream: AudioStream, start_time: float = 0.0, window_seconds: float = 0.0, override_step_size: int = 0) -> _Decoder:
	last_error = ""
	if stream == null:
		last_error = "Stream is null."
		return null

	var playback_source := _make_non_looping_copy(stream)
	var playback: AudioStreamPlayback = playback_source.instantiate_playback()
	if playback == null:
		last_error = "instantiate_playback() failed - unsupported stream type %s." % stream.get_class()
		return null
	if not playback.has_method("mix_audio"):
		last_error = "AudioStreamPlayback.mix_audio() is missing. WaveformBaker needs Godot 4.5 or newer."
		return null

	var mix_rate := AudioServer.get_mix_rate()
	if mix_rate <= 0:
		mix_rate = 44100

	var step := override_step_size if override_step_size > 0 else step_size
	var stream_length := stream.get_length()

	var expected_frames := 0
	var frame_limit := 0
	if window_seconds > 0.0:
		# a slice: decode exactly that many frames, no global limit involved
		expected_frames = int(window_seconds * mix_rate)
		frame_limit = expected_frames
	else:
		expected_frames = int(stream_length * mix_rate)
		if max_seconds > 0.0:
			frame_limit = int(max_seconds * mix_rate)

	if expected_frames <= 0 and window_seconds > 0.0:
		last_error = "The requested window is empty (stream length 0?)."
		return null
	# expected_frames == 0 for a full-file bake of a stream with an unknown
	# length: the decoder then relies on mix_audio() running dry / silence.

	return _Decoder.new(playback, step, chunk_frames, mix_rate, expected_frames, frame_limit, maxf(start_time, 0.0))


func _create_range_decoder(stream: AudioStream, start_time: float, window_seconds: float, range_step_size: int) -> _Decoder:
	if window_seconds <= 0.0:
		last_error = "bake_stream_range(): window_seconds must be > 0."
		return null
	return _create_decoder(stream, start_time, window_seconds, range_step_size)


## Duplicates the stream (cheap for compressed formats) and disables looping so
## that decoding a looped stream terminates.
func _make_non_looping_copy(stream: AudioStream) -> AudioStream:
	var copy := stream.duplicate(false) as AudioStream
	if copy == null:
		copy = stream
	if copy is AudioStreamWAV:
		(copy as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_DISABLED
	elif copy is AudioStreamMP3:
		(copy as AudioStreamMP3).loop = false
	elif copy is AudioStreamOggVorbis:
		(copy as AudioStreamOggVorbis).loop = false
	return copy


func _next_process_frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame


func _cache_path(audio_path: String) -> String:
	var stamp := 0
	if FileAccess.file_exists(audio_path):
		stamp = FileAccess.get_modified_time(audio_path)
	var key := "%s_%d_%d" % [audio_path.md5_text(), stamp, step_size]
	return cache_dir.path_join(key + ".res")


func _load_from_cache(audio_path: String) -> WaveformData:
	if not use_cache:
		return null
	var path := _cache_path(audio_path)
	if not ResourceLoader.exists(path):
		return null
	var cached := ResourceLoader.load(path)
	if cached is WaveformData:
		return cached as WaveformData
	return null


func _save_to_cache(audio_path: String, data: WaveformData) -> void:
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var path := _cache_path(audio_path)
	var error := ResourceSaver.save(data, path)
	if error != OK:
		push_warning("WaveformBaker: could not write cache file %s (error %d)." % [path, error])


## Streaming decoder: pulls a few chunks of audio per [method step] call so both
## the synchronous and the yielding code paths share the same hot loop.
class _Decoder:
	var finished := false
	var frames_decoded := 0
	var stereo_detected := false

	var min_left := PackedFloat32Array()
	var max_left := PackedFloat32Array()
	var rms_left := PackedFloat32Array()
	var min_right := PackedFloat32Array()
	var max_right := PackedFloat32Array()
	var rms_right := PackedFloat32Array()

	var _playback: AudioStreamPlayback
	var _step_size: int
	var _chunk_frames: int
	var _mix_rate: int
	var _expected_frames: int
	var _frame_limit: int
	var _silent_frames := 0
	var _window_start := 0.0

	# running accumulators for the slot currently being filled
	var _slot_frames := 0
	var _slot_min_l := 1.0
	var _slot_max_l := -1.0
	var _slot_sq_l := 0.0
	var _slot_min_r := 1.0
	var _slot_max_r := -1.0
	var _slot_sq_r := 0.0

	func _init(playback: AudioStreamPlayback, step_size: int, chunk_frames: int, mix_rate: int, expected_frames: int, frame_limit: int, window_start: float = 0.0) -> void:
		_playback = playback
		_step_size = maxi(step_size, 1)
		_chunk_frames = maxi(chunk_frames, 256)
		_mix_rate = mix_rate
		_expected_frames = maxi(expected_frames, 0)
		_frame_limit = frame_limit
		_window_start = maxf(window_start, 0.0)
		_playback.start(_window_start)

	## Decodes up to [param chunk_budget] chunks. Returns true when the stream ended.
	##
	## Three ways to stop, because different playback classes report the end of a
	## stream differently (some return 0 frames, some keep returning silence):
	## 1. `mix_audio()` returns nothing,
	## 2. the frame count taken from `stream.get_length()` is reached,
	## 3. no length is known and the mixer has been silent for two seconds.
	func step(chunk_budget: int) -> bool:
		var budget := maxi(chunk_budget, 1)
		while not finished and budget > 0:
			budget -= 1
			var chunk := _playback.mix_audio(1.0, _chunk_frames)
			var count := chunk.size()
			if count == 0:
				finished = true
				break

			var chunk_peak := _consume(chunk, count)
			if chunk_peak > 0.0:
				_silent_frames = 0
			else:
				_silent_frames += count
			frames_decoded += count

			if _frame_limit > 0 and frames_decoded >= _frame_limit:
				finished = true
			elif _expected_frames > 0 and frames_decoded >= _expected_frames:
				finished = true
			elif _expected_frames <= 0 and _silent_frames > _mix_rate * 2:
				finished = true
		return finished

	## 0..1 progress guess based on the stream length.
	func get_ratio() -> float:
		if finished or _expected_frames <= 0:
			return 1.0 if finished else 0.0
		return clampf(float(frames_decoded) / float(_expected_frames), 0.0, 1.0)

	func finish() -> WaveformData:
		if _playback != null:
			_playback.stop()
			_playback = null
		_flush_slot()

		# Chunks are decoded in batches, so the last one can overshoot the real end
		# of the stream by up to chunk_frames. Trim it so `duration` matches the file.
		var decoded := frames_decoded
		if _expected_frames > 0 and decoded > _expected_frames:
			decoded = _expected_frames
			var keep := clampi(int(ceil(float(_expected_frames) / float(_step_size))), 1, min_left.size())
			if keep > 0 and keep < min_left.size():
				min_left.resize(keep)
				max_left.resize(keep)
				rms_left.resize(keep)
				min_right.resize(keep)
				max_right.resize(keep)
				rms_right.resize(keep)

		var data := WaveformData.new()
		data.sample_rate = _mix_rate
		data.step_size = _step_size
		data.frame_count = decoded
		data.duration = float(decoded) / float(_mix_rate)
		data.window_start = _window_start
		data.channels = 2 if stereo_detected else 1
		data.min_l = min_left
		data.max_l = max_left
		data.rms_l = rms_left
		if stereo_detected:
			data.min_r = min_right
			data.max_r = max_right
			data.rms_r = rms_right
		else:
			data.min_r = PackedFloat32Array()
			data.max_r = PackedFloat32Array()
			data.rms_r = PackedFloat32Array()
		return data

	## Folds a chunk of frames into the envelope. Returns the chunk's peak
	## amplitude (used to detect the end of streams with an unknown length).
	func _consume(chunk: PackedVector2Array, count: int) -> float:
		var chunk_peak := 0.0
		for i in count:
			var frame := chunk[i]
			var left := frame.x
			var right := frame.y

			var magnitude := maxf(absf(left), absf(right))
			if magnitude > chunk_peak:
				chunk_peak = magnitude

			if left < _slot_min_l:
				_slot_min_l = left
			if left > _slot_max_l:
				_slot_max_l = left
			_slot_sq_l += left * left

			if right < _slot_min_r:
				_slot_min_r = right
			if right > _slot_max_r:
				_slot_max_r = right
			_slot_sq_r += right * right

			if not stereo_detected and absf(left - right) > 0.00001:
				stereo_detected = true

			_slot_frames += 1
			if _slot_frames >= _step_size:
				_flush_slot()
		return chunk_peak

	func _flush_slot() -> void:
		if _slot_frames <= 0:
			return
		var count := float(_slot_frames)
		min_left.append(_slot_min_l)
		max_left.append(_slot_max_l)
		rms_left.append(sqrt(_slot_sq_l / count))
		min_right.append(_slot_min_r)
		max_right.append(_slot_max_r)
		rms_right.append(sqrt(_slot_sq_r / count))
		_slot_frames = 0
		_slot_min_l = 1.0
		_slot_max_l = -1.0
		_slot_sq_l = 0.0
		_slot_min_r = 1.0
		_slot_max_r = -1.0
		_slot_sq_r = 0.0
