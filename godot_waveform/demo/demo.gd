extends Control
## Demo for the waveform toolkit.
##
## * loads `res://samples/demo_track.wav` on startup: the audio is decoded **once**
##   and cached as a multi-resolution pyramid in `user://waveform_cache/`, so every
##   later load of the same file is instant
## * "Open audio…" (or drop a file on the window) loads any .wav / .ogg / .mp3
## * click / drag the waveform to scrub, "Play" to listen
## * mouse wheel over the waveform zooms into the time axis (Shift+wheel or
##   middle/right drag pans), "Fit" goes back to the whole track
## * Zooming picks a resolution level out of the pyramid - no re-decoding, no
##   quality switch, no stall while the song plays
## * "Follow" scrolls the view along with the song - page flips, or the playhead
##   pinned to the middle with the waveform sliding underneath
## * "Zoom at" decides what the mouse wheel keeps in place: the cursor, the
##   playhead or the centre
## * "Quality" trades the full gradient render for a flat preview while zooming
##   (auto keeps it smooth on slow machines, full is the prettiest, fast is flat)
## * the waveform can be resized vertically (Height slider, or drag its bottom
##   edge) and its vertical scale changed with the Scale slider
## * while playing, the gradient at the playhead flares on every kick: it is driven
##   by the **low band only** (30-100 Hz) with a transient detector, so mid and high
##   frequencies barely move it
## * "Export PNG" writes the currently visible window as a 1600x420 PNG
## * "Smooth" styles the bars and the shader visualiser in the bottom right corner
##   moves with the same bass energy as the playhead pulse

const SAMPLE_AUDIO := "res://samples/demo_track.wav"
const EXPORT_DIR := "res://exports"
## Name of the bus the player uses; created on demand with a spectrum analyser.
const AUDIO_BUS := "WaveformDemo"
## Frequency window treated as "kick / bass". Everything above it is ignored on
## purpose: this is what keeps the pulse kick-driven instead of treble-driven.
const BASS_RANGE := Vector2(30.0, 100.0)
## How much of the level must stand out above the slow average to count as a hit.
const KICK_EMPHASIS := 2.0

var _view: WaveformView
var _player: AudioStreamPlayer
var _loader: WaveformLoader
var _open_dialog: FileDialog
var _status: Label
var _progress: ProgressBar
var _play_button: Button
var _export_button: Button
var _mode_option: OptionButton
var _zoom_label: Label
var _scroll: HSlider
var _smooth_slider: HSlider
var _quality_option: OptionButton
var _anchor_option: OptionButton
var _follow_option: OptionButton
var _height_slider: HSlider
var _scale_slider: HSlider
var _pulse_check: CheckBox
var _visualizer: WaveformVisualizer
var _analyzer: AudioEffectSpectrumAnalyzerInstance

var _pyramid: WaveformPyramid
var _syncing_scroll := false
var _current_path := ""
var _busy := false
var _pulse_level := 0.0
var _bass_slow := 0.0
var _bass_peak := 0.0


func _ready() -> void:
	_loader = WaveformLoader.new()
	_loader.progress.connect(_on_load_progress)
	_loader.stage_changed.connect(_on_load_stage)
	_build_ui()
	_setup_audio_bus()
	_player = AudioStreamPlayer.new()
	_player.bus = AUDIO_BUS
	_player.finished.connect(_on_player_finished)
	add_child(_player)

	if ResourceLoader.exists(SAMPLE_AUDIO) or FileAccess.file_exists(SAMPLE_AUDIO):
		_load_file(SAMPLE_AUDIO)
	else:
		_status.text = "Drop a .wav / .ogg / .mp3 file here, or use \"Open audio…\"."


func _process(delta: float) -> void:
	if not _player.playing or _pyramid == null:
		# let the pulse and the visualiser settle back to silence
		_pulse_level = lerpf(_pulse_level, 0.0, clampf(delta * 6.0, 0.0, 1.0))
		if _pulse_level < 0.002:
			_pulse_level = 0.0
		_view.pulse = _pulse_level
		if _visualizer != null:
			_visualizer.energy = _pulse_level
		return

	var time := _player.get_playback_position() + AudioServer.get_time_since_last_mix()
	time -= AudioServer.get_output_latency()
	_view.playback_ratio = clampf(time / maxf(_duration(), 0.001), 0.0, 1.0)

	_update_pulse(delta)


# --- audio analysis -------------------------------------------------------

## Creates a dedicated bus with a spectrum analyser so the demo can read the level
## of the bass band without touching the master bus.
func _setup_audio_bus() -> void:
	var index := AudioServer.get_bus_index(AUDIO_BUS)
	if index < 0:
		index = AudioServer.bus_count
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, AUDIO_BUS)
		AudioServer.set_bus_send(index, "Master")
		var analyzer := AudioEffectSpectrumAnalyzer.new()
		analyzer.buffer_length = 0.1
		analyzer.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(index, analyzer)
	var effect := AudioServer.get_bus_effect(index, 0)
	if effect is AudioEffectSpectrumAnalyzer:
		_analyzer = AudioServer.get_bus_effect_instance(index, 0) as AudioEffectSpectrumAnalyzerInstance


## Turns the low-frequency level into a pulse value.
##
## Two things make this kick-driven rather than loudness-driven:
## [br]• only 30-100 Hz is measured, so snares, hats and vocals do not matter
## [br]• a transient detector compares the level to its own slow average, so a
##   sustained bass line gives a quiet pulse while a kick drum spikes it
func _update_pulse(delta: float) -> void:
	var level := _bass_level()
	_bass_peak = maxf(level, _bass_peak - delta * 0.25)
	var reference := maxf(_bass_peak, 0.3)
	level = clampf(level / reference, 0.0, 1.0)

	_bass_slow = lerpf(_bass_slow, level, clampf(delta * 2.5, 0.0, 1.0))
	var transient := clampf((level - _bass_slow) * KICK_EMPHASIS + level * 0.35, 0.0, 1.0)

	# fast attack, slower release: reads as a hit instead of a wobble
	var speed := 0.6 if transient > _pulse_level else 0.14
	_pulse_level = clampf(lerpf(_pulse_level, transient, speed), 0.0, 1.0)
	_view.pulse = _pulse_level
	if _visualizer != null:
		_visualizer.energy = _pulse_level


## Raw 0..1 loudness of the low band.
func _bass_level() -> float:
	if _analyzer == null:
		# no analyser (e.g. headless): fall back to the waveform under the playhead
		return clampf(_view.get_amplitude_at_playhead() * 1.6, 0.0, 1.0)
	var magnitude := _analyzer.get_magnitude_for_frequency_range(BASS_RANGE.x, BASS_RANGE.y,
			AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_AVERAGE).length()
	# silence is ~1e-4, a strong kick ~0.3
	return clampf((log(maxf(magnitude, 0.00001)) + 9.2) / 5.0, 0.0, 1.0)


# --- UI -------------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	# toolbar
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	column.add_child(toolbar)

	var open_button := Button.new()
	open_button.text = "Open audio…"
	open_button.pressed.connect(_on_open_pressed)
	toolbar.add_child(open_button)

	_play_button = Button.new()
	_play_button.text = "Play"
	_play_button.toggle_mode = true
	_play_button.disabled = true
	_play_button.toggled.connect(_on_play_toggled)
	toolbar.add_child(_play_button)

	_export_button = Button.new()
	_export_button.text = "Export PNG"
	_export_button.disabled = true
	_export_button.pressed.connect(_on_export_pressed)
	toolbar.add_child(_export_button)

	var fit_button := Button.new()
	fit_button.text = "Fit"
	fit_button.tooltip_text = "Show the whole track (zoom 1x)"
	fit_button.pressed.connect(_on_fit_pressed)
	toolbar.add_child(fit_button)

	toolbar.add_child(VSeparator.new())

	var follow_label := Label.new()
	follow_label.text = "Follow:"
	toolbar.add_child(follow_label)

	_follow_option = OptionButton.new()
	for mode in ["page flip", "centered", "off"]:
		_follow_option.add_item(mode)
	_follow_option.tooltip_text = "Page flip = jump forward in blocks, centered = playhead stays in the middle"
	_follow_option.item_selected.connect(_on_follow_mode_selected)
	toolbar.add_child(_follow_option)

	var mode_label := Label.new()
	mode_label.text = "Channels:"
	toolbar.add_child(mode_label)

	_mode_option = OptionButton.new()
	for mode in ["mix", "stereo", "left", "right"]:
		_mode_option.add_item(mode)
	_mode_option.item_selected.connect(_on_mode_selected)
	toolbar.add_child(_mode_option)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	_zoom_label = Label.new()
	_zoom_label.text = "zoom 1.0x"
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_zoom_label.custom_minimum_size = Vector2(360, 0)
	toolbar.add_child(_zoom_label)

	# style row
	var style_row := HBoxContainer.new()
	style_row.add_theme_constant_override("separation", 8)
	column.add_child(style_row)

	var smooth_label := Label.new()
	smooth_label.text = "Smooth:"
	style_row.add_child(smooth_label)

	_smooth_slider = HSlider.new()
	_smooth_slider.min_value = 0
	_smooth_slider.max_value = 8
	_smooth_slider.step = 1
	_smooth_slider.value = 0
	_smooth_slider.custom_minimum_size = Vector2(140, 0)
	_smooth_slider.tooltip_text = "Blur radius in columns - softens the envelope"
	_smooth_slider.value_changed.connect(_on_smooth_changed)
	style_row.add_child(_smooth_slider)

	style_row.add_child(VSeparator.new())

	var quality_label := Label.new()
	quality_label.text = "Quality:"
	style_row.add_child(quality_label)

	_quality_option = OptionButton.new()
	for mode in ["auto", "full", "fast"]:
		_quality_option.add_item(mode)
	_quality_option.tooltip_text = "auto = flat preview while zooming, full render when you stop"
	_quality_option.item_selected.connect(_on_quality_selected)
	style_row.add_child(_quality_option)

	var anchor_label := Label.new()
	anchor_label.text = " Zoom at:"
	style_row.add_child(anchor_label)

	_anchor_option = OptionButton.new()
	for mode in ["cursor", "playhead", "center"]:
		_anchor_option.add_item(mode)
	_anchor_option.tooltip_text = "What the mouse wheel keeps in place while zooming"
	_anchor_option.item_selected.connect(_on_zoom_anchor_selected)
	style_row.add_child(_anchor_option)

	_pulse_check = CheckBox.new()
	_pulse_check.text = "Pulse"
	_pulse_check.button_pressed = true
	_pulse_check.tooltip_text = "Gradient at the playhead that flares on every kick"
	_pulse_check.toggled.connect(_on_pulse_toggled)
	style_row.add_child(_pulse_check)

	var style_spacer := Control.new()
	style_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_row.add_child(style_spacer)

	# size row: vertical resizing of the waveform
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 8)
	column.add_child(size_row)

	var height_label := Label.new()
	height_label.text = "Height:"
	size_row.add_child(height_label)

	_height_slider = HSlider.new()
	_height_slider.min_value = 80
	_height_slider.max_value = 560
	_height_slider.step = 1
	_height_slider.value = 300
	_height_slider.custom_minimum_size = Vector2(160, 0)
	_height_slider.tooltip_text = "Height of the waveform in pixels (it can also be dragged at its bottom edge)"
	_height_slider.value_changed.connect(_on_height_changed)
	size_row.add_child(_height_slider)

	var scale_label := Label.new()
	scale_label.text = "Scale:"
	size_row.add_child(scale_label)

	_scale_slider = HSlider.new()
	_scale_slider.min_value = 0.2
	_scale_slider.max_value = 2.5
	_scale_slider.step = 0.05
	_scale_slider.value = 1.0
	_scale_slider.custom_minimum_size = Vector2(160, 0)
	_scale_slider.tooltip_text = "Vertical amplitude scale - independent of zoom"
	_scale_slider.value_changed.connect(_on_scale_changed)
	size_row.add_child(_scale_slider)

	var size_spacer := Control.new()
	size_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_row.add_child(size_spacer)

	# waveform
	_view = WaveformView.new()
	_view.size_flags_vertical = Control.SIZE_FILL
	_view.custom_minimum_size = Vector2(0, 300)
	_view.seek_requested.connect(_on_seek_requested)
	_view.view_changed.connect(_on_view_changed)
	column.add_child(_view)

	# live shader visualiser, floating in the bottom right corner of the waveform
	_build_visualizer()

	_scroll = HSlider.new()
	_scroll.min_value = 0.0
	_scroll.max_value = 1.0
	_scroll.step = 0.00001
	_scroll.value = 0.0
	_scroll.tooltip_text = "Visible window position (zoom in to scroll)"
	_scroll.value_changed.connect(_on_scroll_changed)
	column.add_child(_scroll)

	# footer
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	column.add_child(footer)

	_status = Label.new()
	_status.text = "Idle."
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	footer.add_child(_status)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(220, 0)
	_progress.show_percentage = false
	_progress.visible = false
	footer.add_child(_progress)

	# keeps everything at the top when the window grows, so the waveform height is
	# whatever the slider / drag handle says instead of "all remaining space"
	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(bottom_spacer)

	# file dialog
	_open_dialog = FileDialog.new()
	_open_dialog.title = "Open audio file"
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.use_native_dialog = true
	_open_dialog.add_filter("*.wav,*.ogg,*.mp3", "Audio files")
	_open_dialog.file_selected.connect(_on_file_selected)
	add_child(_open_dialog)


## Adds the shader visualiser as a child of the waveform view, anchored bottom-right.
func _build_visualizer() -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.custom_minimum_size = Vector2(320, 120)
	panel.offset_left = -336
	panel.offset_top = -136
	panel.offset_right = -16
	panel.offset_bottom = -16
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.04, 0.06, 0.72)
	style.set_corner_radius_all(10)
	style.set_border_width_all(1)
	style.border_color = Color(0.35, 0.65, 0.9, 0.28)
	panel.add_theme_stylebox_override("panel", style)
	_view.add_child(panel)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)

	var caption := Label.new()
	caption.text = "live"
	caption.add_theme_font_size_override("font_size", 10)
	caption.modulate = Color(0.72, 0.82, 0.95, 0.65)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(caption)

	_visualizer = WaveformVisualizer.new()
	_visualizer.custom_minimum_size = Vector2(300, 96)
	_visualizer.wave_color = Color(0.42, 0.82, 1.0, 1.0)
	_visualizer.lines = 56
	_visualizer.intensity = 0.88
	_visualizer.frequency = 0.09
	_visualizer.idle_level = 0.18
	_visualizer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_visualizer)


func _on_smooth_changed(value: float) -> void:
	_view.smoothing = int(value)
	_status.text = "Smoothing: %d column%s" % [_view.smoothing, "" if _view.smoothing == 1 else "s"]


func _on_pulse_toggled(pressed: bool) -> void:
	_view.pulse_enabled = pressed
	if not pressed:
		_view.pulse = 0.0


func _on_follow_mode_selected(index: int) -> void:
	_view.follow_playhead = index < 2
	if index < 2:
		_view.follow_style = ["page", "center"][index]
	_status.text = "Follow: %s" % ["page flip", "centered", "off"][clampi(index, 0, 2)]


func _on_quality_selected(index: int) -> void:
	_view.preview_quality = ["auto", "full", "fast"][clampi(index, 0, 2)]
	_status.text = "Render quality: %s" % _view.preview_quality


func _on_zoom_anchor_selected(index: int) -> void:
	_view.zoom_anchor = ["cursor", "playhead", "center"][clampi(index, 0, 2)]
	_status.text = "Zoom anchored at the %s" % _view.zoom_anchor


func _on_height_changed(value: float) -> void:
	_view.custom_minimum_size = Vector2(0, value)
	_view.update_minimum_size()


func _on_scale_changed(value: float) -> void:
	_view.amplitude_scale = value


func _on_open_pressed() -> void:
	_open_dialog.popup_centered_ratio(0.7)


func _on_file_selected(path: String) -> void:
	_load_file(path)


func _on_mode_selected(index: int) -> void:
	_view.channel_mode = ["mix", "stereo", "left", "right"][clampi(index, 0, 3)]


func _on_seek_requested(ratio: float) -> void:
	if _pyramid == null or _player.stream == null:
		return
	var time := ratio * _duration()
	if _player.playing:
		_player.seek(time)
	else:
		_player.play(time)
		_play_button.set_pressed_no_signal(true)
	_view.playback_ratio = ratio


func _on_play_toggled(pressed: bool) -> void:
	if _player.stream == null:
		_play_button.set_pressed_no_signal(false)
		return
	if pressed:
		_player.play()
	else:
		_player.stop()
		_view.playback_ratio = -1.0
		_pulse_level = 0.0


func _on_player_finished() -> void:
	_play_button.set_pressed_no_signal(false)
	_view.playback_ratio = -1.0
	_pulse_level = 0.0


func _on_fit_pressed() -> void:
	_view.reset_view()
	_sync_zoom_ui()


func _on_view_changed(_start_ratio: float, _zoom: float) -> void:
	_sync_zoom_ui()
	# the view can be resized by dragging its bottom edge - follow it with the slider
	if _height_slider != null and not is_equal_approx(_height_slider.value, _view.size.y):
		_height_slider.set_value_no_signal(_view.size.y)


func _on_scroll_changed(value: float) -> void:
	if _syncing_scroll:
		return
	_view.set_view(value)


func _sync_zoom_ui() -> void:
	if _view == null or _zoom_label == null or _scroll == null:
		return

	var visible := _view.get_visible_fraction()
	var view_range := _view.get_view_range()
	var zoom := _view.zoom

	_syncing_scroll = true
	_scroll.max_value = maxf(1.0 - visible, 0.00001)
	_scroll.value = _view.view_start
	_scroll.editable = zoom > 1.001
	_syncing_scroll = false

	if zoom <= 1.001:
		_zoom_label.text = "zoom 1.0x · whole track · %d frames/slot" % _view.get_effective_step_size()
		return

	var seconds := (view_range.y - view_range.x) * _duration()
	var levels := 0
	if _pyramid != null:
		levels = _pyramid.get_level_count()
	_zoom_label.text = "zoom %.1fx · %.2f s window · %d frames/slot · %d levels" % [
		zoom, seconds, _view.get_effective_step_size(), levels,
	]


# --- loading --------------------------------------------------------------

func _duration() -> float:
	return _pyramid.duration if _pyramid != null else 0.0


## Loads a file through [WaveformLoader]: cache first, decode in the background if
## it was never seen before. The current waveform stays on screen meanwhile.
func _load_file(path: String) -> void:
	if _busy:
		return
	_busy = true
	_current_path = path
	# stop the old track so the playhead does not run on while the new one loads
	if _player.playing:
		_player.stop()
	_play_button.set_pressed_no_signal(false)
	_view.playback_ratio = -1.0
	_pulse_level = 0.0
	_view.pulse = 0.0
	_play_button.disabled = true
	_export_button.disabled = true
	_progress.visible = true
	_progress.value = 0.0
	_status.text = "Loading %s…" % path.get_file()

	var started := Time.get_ticks_msec()
	var pyramid := await _loader.load_pyramid(path)
	var elapsed := Time.get_ticks_msec() - started

	_busy = false
	_progress.visible = false

	if pyramid == null:
		_status.text = "Failed: %s" % _loader.last_error
		push_error(_loader.last_error)
		return

	_pyramid = pyramid
	_view.pyramid = pyramid
	_sync_zoom_ui()

	var stream := WaveformBaker.load_audio_stream(path)
	if stream != null:
		_player.stream = stream
		_play_button.disabled = false
		_export_button.disabled = false
	else:
		_status.text = "Loaded the waveform, but the stream could not be played back."

	var source := "cache" if _loader.last_source == "cache" else "decoded"
	_status.text = "%s · %s · %s in %d ms" % [
		path.get_file(), source, pyramid.describe(), elapsed,
	]
	print("Waveform loaded: ", pyramid.describe(), " (", source, ", ", elapsed, " ms)")


func _on_load_progress(ratio: float) -> void:
	_progress.value = clampf(ratio, 0.0, 1.0) * 100.0


func _on_load_stage(stage: String) -> void:
	match stage:
		"cache":
			_status.text = "Reading cached waveform…"
		"decode":
			_status.text = "Decoding audio (first time only)…"
		"levels":
			_status.text = "Building resolution levels…"
		"save":
			_status.text = "Writing cache…"


# --- export ---------------------------------------------------------------

func _on_export_pressed() -> void:
	if _pyramid == null:
		return
	var base := _current_path.get_file().get_basename()
	if base.is_empty():
		base = "waveform"

	# Export exactly what is on screen - and pick the pyramid level that suits the
	# 1600 px output rather than the (possibly coarser) one used for the view.
	var source := _view.get_render_source()
	var export_level: WaveformData = source["data"]
	if _pyramid.get_level_count() > 0:
		export_level = _pyramid.pick(1600, _view.get_visible_fraction())
	var zoom := _view.zoom
	var options := {
		"width": 1600,
		"height": 420,
		"supersample": 2,
		"channel_mode": _view.channel_mode,
		"padding": 12,
		"view_start": source["view_start"],
		"view_end": source["view_end"],
		"smoothing": _view.smoothing,
	}

	var suffix := "_waveform" if zoom <= 1.001 else "_waveform_z%dx" % int(round(zoom))
	var target := EXPORT_DIR.path_join("%s%s.png" % [base, suffix])
	var error := WaveformRenderer.save_png(export_level, target, options)
	if error != OK:
		target = "user://%s%s.png" % [base, suffix]
		error = WaveformRenderer.save_png(export_level, target, options)

	if error == OK:
		var absolute := ProjectSettings.globalize_path(target)
		_status.text = "PNG written to %s" % absolute
		print("Waveform PNG written to: ", absolute)
	else:
		_status.text = "PNG export failed (error %d)" % error
		push_error("PNG export failed with error %d" % error)


# --- drag and drop --------------------------------------------------------

func _can_drop_data(_at_position: Vector2, dropped: Variant) -> bool:
	return dropped is Dictionary and dropped.has("files") \
			and dropped["files"] is PackedStringArray and dropped["files"].size() > 0


func _drop_data(_at_position: Vector2, dropped: Variant) -> void:
	var files: PackedStringArray = dropped["files"]
	if files.size() > 0:
		_load_file(files[0])
