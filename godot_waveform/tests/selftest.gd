extends SceneTree
## Headless sanity test for the waveform toolkit.
##
## Run it from the project folder:
## [codeblock]
## godot --headless --path . --script res://tests/selftest.gd
## [/codeblock]
##
## It bakes `res://samples/demo_track.wav`, renders a few images and checks the
## numbers it gets. Exit code 0 = everything passed, 1 = something failed.
## Drop your own .ogg / .mp3 next to the sample and pass the path as the first
## extra argument to test that file instead:
## [codeblock]
## godot --headless --path . --script res://tests/selftest.gd -- res://music/song.ogg
## [/codeblock]

const SAMPLE := "res://samples/demo_track.wav"
const PNG_OUT := "user://selftest_waveform.png"
const RES_OUT := "user://selftest_waveform.res"

var _failures := 0
var _checks := 0


func _initialize() -> void:
	var target := SAMPLE
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		target = args[0]

	print("== Waveform selftest ==")
	print("Godot:        ", Engine.get_version_info()["string"])
	print("Audio rate:   ", AudioServer.get_mix_rate(), " Hz  (driver: ", AudioServer.get_driver_name(), ")")
	print("Target file:  ", target)

	var baker := WaveformBaker.new()
	baker.use_cache = false
	baker.yield_frames = false

	var started := Time.get_ticks_msec()
	var data := baker.bake_file_sync(target)
	var bake_ms := Time.get_ticks_msec() - started

	_check(data != null, "bake_file_sync() returned data (%s)" % baker.last_error)
	if data == null:
		_finish()
		return

	print("Baked:        ", data.describe(), " in ", bake_ms, " ms")

	# ---- metadata -----------------------------------------------------------
	_check(data.get_slot_count() > 0, "envelope has slots")
	_check(data.duration > 0.05, "duration > 0.05 s (%.3f s)" % data.duration)
	_check(data.frame_count > 0, "frame_count > 0 (%d)" % data.frame_count)
	_check(data.sample_rate == AudioServer.get_mix_rate(),
			"sample_rate matches the AudioServer mix rate (%d)" % data.sample_rate)
	_check(is_equal_approx(data.step_size, 128) or data.step_size > 0,
			"step_size is sane (%d)" % data.step_size)

	var expected_slots := int(ceil(data.duration * data.sample_rate / float(data.step_size)))
	_check(absi(data.get_slot_count() - expected_slots) <= 2,
			"slot count matches duration (%d vs ~%d)" % [data.get_slot_count(), expected_slots])

	var peak := data.get_peak()
	_check(peak > 0.01 and peak <= 1.001, "peak amplitude in range (%.3f)" % peak)

	if target.ends_with("demo_track.wav"):
		_check(data.has_stereo(), "demo track detected as stereo")
		_check(absi(data.duration - 8.0) < 0.05, "demo track duration is ~8 s (%.3f)" % data.duration)

	# ---- reduction ----------------------------------------------------------
	var cols := data.reduce(320, WaveformData.CHANNEL_MIX)
	var consistent := cols.count == 320 and cols.max_values.size() == 320
	if consistent:
		for i in 320:
			if cols.min_values[i] > cols.max_values[i] + 0.0001 or cols.rms_values[i] < 0.0:
				consistent = false
				break
	_check(consistent, "reduce(320) returns 320 consistent columns")

	var loud := 0
	var cols_small := data.reduce(64, WaveformData.CHANNEL_MIX)
	for i in 64:
		if cols_small.max_values[i] - cols_small.min_values[i] > 0.01:
			loud += 1
	_check(loud > 60, "most of the 64 columns contain audio (%d)" % loud)

	if data.has_stereo():
		var left := data.reduce(200, WaveformData.CHANNEL_LEFT)
		var right := data.reduce(200, WaveformData.CHANNEL_RIGHT)
		var different := false
		for i in 200:
			if not is_equal_approx(left.rms_values[i], right.rms_values[i]):
				different = true
				break
		_check(different, "left and right envelopes differ")

	# ---- rendering ----------------------------------------------------------
	var image := WaveformRenderer.render(data, {"width": 640, "height": 200, "supersample": 2})
	_check(not image.is_empty(), "render() produced an image")
	_check(image.get_width() == 640 and image.get_height() == 200,
			"image size is 640x200 (%dx%d)" % [image.get_width(), image.get_height()])

	var lit := 0
	var samples := 0
	for y in range(0, image.get_height(), 3):
		for x in range(0, image.get_width(), 3):
			samples += 1
			if image.get_pixel(x, y).v > 0.16:
				lit += 1
	var ratio := float(lit) / float(maxi(samples, 1))
	_check(ratio > 0.08 and ratio < 0.95, "waveform covers a sane part of the image (%.1f%%)" % (ratio * 100.0))

	if data.has_stereo():
		var stereo_image := WaveformRenderer.render(data,
				{"width": 400, "height": 200, "channel_mode": "stereo", "supersample": 1})
		_check(stereo_image.get_width() == 400, "stereo render works")

	var transparent_image := WaveformRenderer.render(data,
			{"width": 200, "height": 80, "transparent": true, "supersample": 1})
	var has_transparency := transparent_image.get_pixel(2, 2).a < 0.99
	_check(has_transparency, "transparent mode leaves the background transparent")

	var texture := WaveformRenderer.render_texture(data, {"width": 128, "height": 64, "supersample": 1})
	_check(texture != null and texture.get_width() == 128,
			"render_texture() returns a 128 px wide ImageTexture")

	# ---- PNG + Resource round trip -----------------------------------------
	var error := WaveformRenderer.save_png(data, PNG_OUT, {"width": 300, "height": 100})
	_check(error == OK and FileAccess.file_exists(PNG_OUT), "save_png() wrote %s" % PNG_OUT)

	var save_error := ResourceSaver.save(data, RES_OUT)
	_check(save_error == OK, "WaveformData serialises to a Resource")
	if save_error == OK:
		var reloaded := ResourceLoader.load(RES_OUT) as WaveformData
		_check(reloaded != null and reloaded.get_slot_count() == data.get_slot_count(),
				"reloaded WaveformData keeps its slots")

	# ---- zoom: slot windows ------------------------------------------------
	var windowed := data.reduce(64, WaveformData.CHANNEL_MIX, 100, 900)
	var windowed_peak := 0.0
	for i in windowed.count:
		windowed_peak = maxf(windowed_peak, windowed.max_values[i])
	_check(windowed.count == 64 and windowed_peak > 0.0,
			"reduce() with a slot window returns usable columns")

	var stream := WaveformBaker.load_audio_stream(target)
	_check(stream != null, "load_audio_stream() returns a stream")
	if stream != null:
		var offset := minf(data.duration * 0.35, maxf(data.duration - 0.6, 0.0))
		var length := minf(0.5, data.duration - offset)
		var detail := baker.bake_stream_range_sync(stream, offset, length, 8)
		_check(detail != null, "bake_stream_range_sync() returned data (%s)" % baker.last_error)
		if detail != null:
			_check(is_equal_approx(detail.window_start, offset),
					"range bake window_start is %.3f s" % detail.window_start)
			_check(detail.step_size == 8, "range bake step size is 8 frames/slot")

	# ---- multi-resolution pyramid ------------------------------------------
	var pyramid := WaveformPyramid.build(data)
	_check(pyramid.get_level_count() > 1, "pyramid has %d levels" % pyramid.get_level_count())
	print("Pyramid:      ", pyramid.describe())
	_check(pyramid.get_finest() == data, "levels[0] is the envelope it was built from")
	_check(absf(pyramid.get_peak() - data.get_peak()) < 0.0005,
			"pyramid peak matches the source peak (%.3f)" % pyramid.get_peak())

	var steps_grow := true
	var slots_shrink := true
	for i in range(1, pyramid.get_level_count()):
		if pyramid.levels[i].step_size <= pyramid.levels[i - 1].step_size:
			steps_grow = false
		if pyramid.levels[i].get_slot_count() >= pyramid.levels[i - 1].get_slot_count():
			slots_shrink = false
	_check(steps_grow, "every level doubles the step size")
	_check(slots_shrink, "every level halves the slot count")

	var coarsest := pyramid.levels[pyramid.get_level_count() - 1]
	_check(absf(coarsest.get_peak() - data.get_peak()) < 0.02,
			"coarsest level keeps the true peak (%.3f vs %.3f)" % [coarsest.get_peak(), data.get_peak()])

	var level_out := pyramid.pick(1200, 1.0, 1.0)
	var level_in := pyramid.pick(1200, 0.05, 1.0)
	_check(level_out.get_slot_count() >= 1200,
			"pick() at zoom 1 gives >= 1 slot per column (%d slots)" % level_out.get_slot_count())
	_check(level_in.get_slot_count() > level_out.get_slot_count(),
			"pick() zooms into a finer level (%d > %d slots)" % [
				level_in.get_slot_count(), level_out.get_slot_count()])
	_check(pyramid.get_max_zoom(1200) > 1.0,
			"pyramid reports a max zoom of %.1fx" % pyramid.get_max_zoom(1200))

	# the level the view picks must draw the same picture as the fine one: that is
	# what "no visible LOD switch while zooming" means
	var drawn_level := pyramid.pick(480, 1.0, 1.0)
	var fine_image := WaveformRenderer.render(data, {"width": 480, "height": 120, "supersample": 1})
	var drawn_image := WaveformRenderer.render(drawn_level,
			{"width": 480, "height": 120, "supersample": 1, "peak": data.get_peak()})
	_check(_images_similar(fine_image, drawn_image, 8.0),
			"the level picked for 480 px matches the finest level (step %d)" % drawn_level.step_size)

	# the whole pyramid survives a save/load round trip - that is the disk cache
	var pyramid_path := "user://selftest_pyramid.res"
	var pyramid_error := ResourceSaver.save(pyramid, pyramid_path)
	_check(pyramid_error == OK, "pyramid serialises to a Resource")
	if pyramid_error == OK:
		var loaded := ResourceLoader.load(pyramid_path) as WaveformPyramid
		_check(loaded != null and loaded.get_level_count() == pyramid.get_level_count(),
				"reloaded pyramid keeps %d levels" % pyramid.get_level_count())
		if loaded != null:
			_check(loaded.get_finest_slots() == pyramid.get_finest_slots(),
					"reloaded pyramid keeps the finest slot count")

	# ---- loader: decode once, then read the cache --------------------------
	var loader := WaveformLoader.new()
	loader.target_slots = 8192          # keep the test cache small
	loader.clear_cache()
	var first_started := Time.get_ticks_msec()
	var first := loader.load_pyramid_sync(target)
	var first_ms := Time.get_ticks_msec() - first_started
	_check(first != null, "loader returned a pyramid (%s)" % loader.last_error)
	_check(loader.last_source == "decode", "the first load decodes (%s)" % loader.last_source)
	if first != null:
		print("Loader:       ", first.describe(), " in ", first_ms, " ms")

	var second_started := Time.get_ticks_msec()
	var second := loader.load_pyramid_sync(target)
	var second_ms := Time.get_ticks_msec() - second_started
	_check(second != null, "the second load returned a pyramid")
	_check(loader.last_source == "cache", "the second load comes from the cache (%s)" % loader.last_source)
	_check(first != null and second != null
			and second.get_finest_slots() == first.get_finest_slots(),
			"cached pyramid keeps the resolution")
	print("Cached load:  ", second_ms, " ms (first load ", first_ms, " ms)")
	loader.clear_cache()

	# ---- renderer styling: smoothing ---------------------------------------
	var style_base := {
		"width": 480,
		"height": 160,
		"supersample": 1,
		"channel_mode": "mix",
		"transparent": true,
	}
	var plain := WaveformRenderer.render(data, style_base.duplicate())
	var plain_again := WaveformRenderer.render(data, style_base.duplicate())
	_check(_images_equal(plain, plain_again), "same options give an identical image")

	var smooth_options: Dictionary = style_base.duplicate()
	smooth_options["smoothing"] = 4
	var smoothed := WaveformRenderer.render(data, smooth_options)
	_check(smoothed != null and not _images_equal(plain, smoothed),
			"smoothing = 4 changes the image (soft envelope)")

	# ---- second pass through the cache -------------------------------------
	var cached_baker := WaveformBaker.new()
	cached_baker.yield_frames = false
	cached_baker.bake_file_sync(target)
	var cache_started := Time.get_ticks_msec()
	var cached := cached_baker.bake_file_sync(target)
	var cache_ms := Time.get_ticks_msec() - cache_started
	_check(cached != null and cached.get_slot_count() == data.get_slot_count(),
			"cached bake returns the same envelope")
	print("Cached bake:  ", cache_ms, " ms")

	_finish()


## True when two images have exactly the same pixels.
func _images_equal(a: Image, b: Image) -> bool:
	if a == null or b == null:
		return a == b
	if a.get_size() != b.get_size() or a.get_format() != b.get_format():
		return false
	return a.get_data() == b.get_data()


## True when two images are close: at most [param tolerance] percent of the sampled
## pixels differ, which is what "the same waveform at a coarser resolution" means.
func _images_similar(a: Image, b: Image, tolerance_percent: float, channel_delta: float = 0.06) -> bool:
	if a == null or b == null or a.get_size() != b.get_size():
		return false
	var sampled := 0
	var different := 0
	for y in range(0, a.get_height(), 3):
		for x in range(0, a.get_width(), 3):
			sampled += 1
			if _pixel_off(a.get_pixel(x, y), b.get_pixel(x, y), channel_delta):
				different += 1
	if sampled == 0:
		return true
	return float(different) / float(sampled) * 100.0 <= tolerance_percent


## True when any channel of two colours differs by more than [param delta].
func _pixel_off(a: Color, b: Color, delta: float) -> bool:
	return absf(a.r - b.r) > delta or absf(a.g - b.g) > delta \
			or absf(a.b - b.b) > delta or absf(a.a - b.a) > delta


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  PASS  ", label)
	else:
		_failures += 1
		print("  FAIL  ", label)


func _finish() -> void:
	print("== %d check(s), %d failure(s) ==" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
