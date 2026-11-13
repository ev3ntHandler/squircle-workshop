@tool
class_name WaveformLoader
extends RefCounted
## Loads a whole track into a [WaveformPyramid] - from the disk cache when it can,
## by decoding in the background when it cannot.
##
## The point of the pyramid plus cache is that everything the view needs later
## (zooming, panning, seeking, resizing) is already there: the audio is decoded
## **once**, the result is written to `user://waveform_cache/` and every later load
## of the same file is a resource read instead of a decode.
##
## [codeblock]
## var loader := WaveformLoader.new()
## loader.progress.connect(func(r): $Bar.value = r * 100.0)
## loader.stage_changed.connect(func(s): $Status.text = s)
## var pyramid := await loader.load_pyramid("res://music/song.ogg")
## if pyramid == null:
##     push_error(loader.last_error)
## else:
##     $WaveformView.pyramid = pyramid
## [/codeblock]
##
## Signature of the cache key: source path + modification time + size + step size +
## [constant WaveformPyramid.CACHE_VERSION]. Touch the audio file, change
## [member target_slots] or bump the version, and the file is rebuilt instead of
## being read back stale.

## Emitted while loading, 0..1. Sends 1.0 immediately when the cache hits.
signal progress(ratio: float)
## Emitted when the loading stage changes: `"cache"`, `"decode"`, `"levels"`,
## `"save"`, `"ready"`.
signal stage_changed(stage: String)

## Where pyramids are cached.
const CACHE_DIR := "user://waveform_cache"
## Rough number of slots the finest level should have. The step size is chosen to
## hit it, so a 3 s jingle and a 10 minute mix end up with a cache of the same
## order of magnitude (~6 MB for 260k slots: 6 float32 arrays).
const DEFAULT_TARGET_SLOTS := 262144
## Never decode finer than this (frames per slot) - below ~8 the cache grows fast
## while the picture barely changes.
const MIN_STEP := 8
## Never decode coarser than this, otherwise short files lose all detail.
const MAX_STEP := 1024

## Use `user://waveform_cache` when the file was baked before.
var use_cache: bool = true
## Number of slots to aim for in the finest level; higher = more zoom detail and a
## bigger cache.
var target_slots: int = DEFAULT_TARGET_SLOTS
## Force a step size (audio frames per slot) instead of deriving it from
## [member target_slots]. 0 = automatic.
var fine_step: int = 0
## Where to put cache files.
var cache_dir: String = CACHE_DIR
## Human readable error of the last load, empty on success.
var last_error: String = ""
## Where the last pyramid came from: `"cache"` or `"decode"`.
var last_source: String = ""


## Loads [param path] as a pyramid. Await it: the decode yields to the main loop
## between chunks (so the UI keeps running) and the cache is read on a thread.
func load_pyramid(path: String) -> WaveformPyramid:
	last_error = ""
	last_source = ""

	if use_cache:
		var cached := await _read_cache(path)
		if cached != null:
			last_source = "cache"
			stage_changed.emit("ready")
			progress.emit(1.0)
			return cached

	stage_changed.emit("decode")
	var stream := WaveformBaker.load_audio_stream(path)
	if stream == null:
		last_error = "Could not load an audio stream from %s" % path
		return null

	var pyramid := await build_pyramid(stream, path)
	if pyramid == null:
		return null
	last_source = "decode"
	if use_cache:
		stage_changed.emit("save")
		_write_cache(path, pyramid)
	stage_changed.emit("ready")
	progress.emit(1.0)
	return pyramid


## Blocking variant for editor scripts and headless tools. Reads the cache when it
## can, otherwise decodes everything in one go.
func load_pyramid_sync(path: String) -> WaveformPyramid:
	last_error = ""
	last_source = ""
	if use_cache:
		var cached := _read_cache_sync(path)
		if cached != null:
			last_source = "cache"
			progress.emit(1.0)
			return cached

	var stream := WaveformBaker.load_audio_stream(path)
	if stream == null:
		last_error = "Could not load an audio stream from %s" % path
		return null

	var pyramid := build_pyramid_sync(stream, path)
	if pyramid == null:
		return null
	last_source = "decode"
	if use_cache:
		_write_cache(path, pyramid)
	progress.emit(1.0)
	return pyramid


## Decodes [param stream] at the configured resolution and builds the pyramid.
func build_pyramid(stream: AudioStream, source_label: String = "stream") -> WaveformPyramid:
	var baker := WaveformBaker.new()
	baker.use_cache = false
	baker.step_size = _step_for_stream(stream)
	if not baker.progress_changed.is_connected(_on_bake_progress):
		baker.progress_changed.connect(_on_bake_progress)
	var fine: WaveformData = await baker.bake_stream(stream)
	if fine == null:
		last_error = baker.last_error
		return null
	stage_changed.emit("levels")
	var pyramid := WaveformPyramid.build(fine)
	pyramid.source = source_label
	if pyramid.get_level_count() == 0:
		last_error = "Decoded stream produced an empty envelope."
		return null
	return pyramid


## Blocking variant of [method build_pyramid].
func build_pyramid_sync(stream: AudioStream, source_label: String = "stream") -> WaveformPyramid:
	var baker := WaveformBaker.new()
	baker.use_cache = false
	baker.step_size = _step_for_stream(stream)
	var fine := baker.bake_stream_sync(stream)
	if fine == null:
		last_error = baker.last_error
		return null
	var pyramid := WaveformPyramid.build(fine)
	pyramid.source = source_label
	return pyramid if pyramid.get_level_count() > 0 else null


## Step size (frames per slot) that lands the finest level near
## [member target_slots]. Clamped to [constant MIN_STEP] .. [constant MAX_STEP].
func step_for_frames(frames: int) -> int:
	if fine_step > 0:
		return fine_step
	var wanted := maxi(target_slots, 1024)
	var step := int(ceil(float(maxi(frames, 1)) / float(wanted)))
	return clampi(step, MIN_STEP, MAX_STEP)


## Removes every cached pyramid.
func clear_cache() -> void:
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".res"):
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()


## Path of the cache file for [param audio_path] (whether or not it exists).
func cache_path_for(audio_path: String) -> String:
	return _cache_path(audio_path)


# --- internals ------------------------------------------------------------

func _step_for_stream(stream: AudioStream) -> int:
	var frames := int(stream.get_length() * float(AudioServer.get_mix_rate()))
	return step_for_frames(frames)


func _on_bake_progress(ratio: float) -> void:
	# keep a little headroom for the level building / cache save that follow
	progress.emit(clampf(ratio * 0.9, 0.0, 0.9))


func _cache_path(audio_path: String) -> String:
	var stamp := 0
	var size := 0
	if FileAccess.file_exists(audio_path):
		stamp = FileAccess.get_modified_time(audio_path)
		var file := FileAccess.open(audio_path, FileAccess.READ)
		if file != null:
			size = int(file.get_length())
			file.close()
	var key := "%s_%d_%d_%d_%d" % [
		audio_path.md5_text(), stamp, size, fine_step, WaveformPyramid.CACHE_VERSION,
	]
	return cache_dir.path_join(key + ".res")


func _read_cache(audio_path: String) -> WaveformPyramid:
	if not use_cache:
		return null
	var path := _cache_path(audio_path)
	if not ResourceLoader.exists(path):
		return null
	# Threaded load: no hitch on the main thread even for a 20 MB cache file.
	var error := ResourceLoader.load_threaded_request(path, "Resource")
	if error != OK:
		return _read_cache_sync(audio_path)
	var status := ResourceLoader.load_threaded_get_status(path)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await _next_frame()
		status = ResourceLoader.load_threaded_get_status(path)
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		return null
	return _accept(ResourceLoader.load_threaded_get(path))


func _read_cache_sync(audio_path: String) -> WaveformPyramid:
	var path := _cache_path(audio_path)
	if not ResourceLoader.exists(path):
		return null
	return _accept(ResourceLoader.load(path))


func _accept(resource: Resource) -> WaveformPyramid:
	if resource is WaveformPyramid:
		var pyramid := resource as WaveformPyramid
		if pyramid.get_level_count() > 0 and pyramid.get_finest_slots() > 0:
			return pyramid
	return null


func _write_cache(audio_path: String, pyramid: WaveformPyramid) -> void:
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var path := _cache_path(audio_path)
	pyramid.source = audio_path
	var error := ResourceSaver.save(pyramid, path)
	if error != OK:
		push_warning("WaveformLoader: could not write %s (error %d)." % [path, error])


func _next_frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame
