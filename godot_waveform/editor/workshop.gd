extends Control

const GRID_SCRIPT := preload("res://editor/beat_grid_canvas.gd")
const BPM_SCRIPT := preload("res://editor/bpm_graph.gd")
const SELECT_SCRIPT := preload("res://editor/wave_select.gd")
const SLIDER_SCRIPT := preload("res://editor/workshop_slider.gd")
const GRID_NAV_SCRIPT := preload("res://editor/grid_navigator.gd")
const INK := Color("#0b0d11")
const PANEL := Color("#12151b")
const PANEL_ALT := Color("#181c24")
const BORDER := Color("#292f3a")
const MUTED := Color("#9099aa")
const TEXT := Color("#edf1f7")
const ACCENT := Color("#c77dff")
const CYAN := Color("#77d7e8")

var player: AudioStreamPlayer
var loader: WaveformLoader
var waveform: WaveformView
var minimap: WaveformView
var grid: BeatGridCanvas
var note_list: Array[Dictionary] = []
var shape_list: Array[Dictionary] = []
var markers: Array[Dictionary] = []
var layers: Array[Dictionary] = [
	{"name": "Layer 1", "color": Color("#c77dff"), "visible": true, "opacity": 0.9}
]
var current_layer := 0
var history: Array[Dictionary] = []
var history_index := -1
var restoring_history := false
var selected_id := ""
var selected_ids: Array[String] = []
var selected_shape_id := ""
var active_shape_id := ""
var last_placed_position := Vector2(0.5, 0.5)
var brush_notes_placed := 0
var last_brush_position := Vector2(-1, -1)
var preview_grid: BeatGridCanvas
var current_tool := "Pencil"
var snap_enabled := true
var duration := 0.0
var bpm := 128.0
var song_time := 0.0
var playback_speed := 1.0
var approach_rate_value := 1.0
var cursor_smoothness_value := 0.45
var tool_buttons: Dictionary = {}
var waveform_panel: Control
var speed_value_label: Label
var tree_context_menu: PopupMenu
var tree_context_item_id := ""
var audio_loaded := false
var cue_player: AudioStreamPlayer
var cue_timer_remaining := 0.0
var playing := false
var auto_advance := false
var autoplay_cursor := true
var bpm_graph_open := false
var bpm_points: Array[Vector2] = [Vector2(0, 128), Vector2(1, 128)]
var file_path := ""
var status_label: Label
var time_label: Label
var play_button: Button
var bpm_label: Label
var bpm_graph
var wave_overlay
var mini_overlay
var scrub_slider: HSlider
var properties_panel: VBoxContainer
var layer_list: VBoxContainer
var tree_list: VBoxContainer
var library_list: VBoxContainer
var tree_mode := "Tree"
var library_patterns: Array[String] = [
	"Basic 3-note burst", "Zig-zag", "Diagonal run", "Center alternation"
]
var grid_x_slider: HSlider
var grid_y_slider: HSlider
var speed_slider: HSlider
var file_dialog: FileDialog
var timeline_progress: ProgressBar
var search_input: LineEdit
var notes_count_label: Label
var app_content: VBoxContainer
var object_sidebar: PanelContainer
var library_scroll: ScrollContainer
var object_filter_menu: PopupMenu
var object_filter := "All"
var expanded_note_groups: Dictionary = {}
var selected_count_label: Label
var played_count_label: Label
var playback_percent_label: Label
var playback_rate_spin: SpinBox
var grid_x_spin: SpinBox
var grid_y_spin: SpinBox
var beat_division_option: OptionButton
var bpm_value_spin: SpinBox
var bpm_add_button: Button
var bpm_graph_button: Button
var show_grid_check: CheckBox
var show_cursor_check: CheckBox
var extend_boundary_check: CheckBox
var grid_navigator
var grid_area: Control
var layers_panel: PanelContainer
var layers_toggle: Button
var object_tree_scroll: ScrollContainer
var music_volume_slider: HSlider
var hitsound_volume_slider: HSlider
var metronome_volume_slider: HSlider
var startup_audio_prompted := false
var music_bus_name := "WorkshopMusic"
var hitsound_bus_name := "WorkshopHits"
var metronome_bus_name := "WorkshopMetronome"


func _setup_cue_audio() -> void:
	var bus_index := AudioServer.get_bus_index("WorkshopCue")
	if bus_index < 0:
		bus_index = AudioServer.bus_count
		AudioServer.add_bus(bus_index)
		AudioServer.set_bus_name(bus_index, "WorkshopCue")
		AudioServer.set_bus_send(bus_index, "Master")
		var reverb := AudioEffectReverb.new()
		reverb.room_size = 0.72
		reverb.wet = 0.32
		reverb.dry = 0.72
		AudioServer.add_bus_effect(bus_index, reverb)
	cue_player.bus = "WorkshopCue"


func _play_advance_cue(at_time: float) -> void:
	if player == null or player.stream == null or cue_player == null:
		return
	cue_player.stop()
	cue_player.stream = player.stream
	cue_player.pitch_scale = playback_speed
	cue_player.play(clampf(at_time, 0.0, maxf(duration - 0.2, 0.0)))
	cue_timer_remaining = 0.18


func _ready() -> void:
	_build_theme()
	player = AudioStreamPlayer.new()
	player.name = "MusicPlayer"
	add_child(player)
	loader = WaveformLoader.new()
	cue_player = AudioStreamPlayer.new()
	cue_player.name = "AutoAdvanceCue"
	cue_player.volume_db = -14.0
	add_child(cue_player)
	_setup_cue_audio()
	_build_shell()
	_refresh_layers()
	_sync_grid()
	_record_history()
	set_process(true)
	call_deferred("_prompt_for_startup_audio")


func _process(delta: float) -> void:
	if cue_timer_remaining > 0.0:
		cue_timer_remaining -= delta
		if cue_timer_remaining <= 0.0 and cue_player.playing:
			cue_player.stop()
	if minimap != null:
		minimap.zoom = 1.0
		minimap.view_start = 0.0
	if player != null and player.playing and not player.stream_paused:
		song_time = (
			player.get_playback_position()
			+ AudioServer.get_time_since_last_mix()
			- AudioServer.get_output_latency()
		)
		duration = maxf(duration, player.stream.get_length())
		waveform.playback_ratio = clampf(song_time / maxf(duration, 0.01), 0.0, 1.0)
		minimap.playback_ratio = waveform.playback_ratio
		if time_label != null:
			time_label.text = "%s  /  %s" % [_format_time(song_time), _format_time(duration)]
		if timeline_progress != null:
			timeline_progress.value = 100.0 * song_time / maxf(duration, 0.01)
		if scrub_slider != null:
			scrub_slider.value = 100.0 * song_time / maxf(duration, 0.01)
	if wave_overlay != null:
		wave_overlay.notes = note_list
		wave_overlay.markers = markers
		wave_overlay.duration = maxf(duration, 0.01)
		wave_overlay.bar_seconds = _bar_seconds()
		wave_overlay.bpm_points = bpm_points
		wave_overlay.selected_ids = selected_ids
		wave_overlay.visible_layers = grid.visible_layers
		wave_overlay.layer_colors = grid.layer_colors
		wave_overlay.layer_opacities = grid.layer_opacities
		wave_overlay.queue_redraw()
	if mini_overlay != null:
		mini_overlay.notes = note_list
		mini_overlay.markers = markers
		mini_overlay.duration = maxf(duration, 0.01)
		mini_overlay.visible_layers = grid.visible_layers
		mini_overlay.layer_colors = grid.layer_colors
		mini_overlay.layer_opacities = grid.layer_opacities
		mini_overlay.queue_redraw()
	if playback_percent_label != null:
		playback_percent_label.text = "%.1f%%" % (100.0 * song_time / maxf(duration, 0.01))
	if played_count_label != null:
		var played := 0
		for note in note_list:
			if float(note.get("time", 0.0)) <= song_time:
				played += 1
		played_count_label.text = "%d / %d" % [played, note_list.size()]
	if grid != null:
		grid.current_time = song_time
		grid.line_preview_duration = _bar_seconds()
		grid.active_layer_opacity = float(layers[current_layer].opacity)
		grid.shapes = shape_list
		grid.selected_shape_id = selected_shape_id
		grid.animate_notes = audio_loaded
		grid.approach_rate = approach_rate_value
		var target_cursor := (
			_cursor_for_time(song_time) if playing and autoplay_cursor else Vector2(-1, -1)
		)
		if target_cursor.x < 0.0:
			grid.cursor_position = target_cursor
		elif grid.cursor_position.x < 0.0 or cursor_smoothness_value <= 0.0:
			grid.cursor_position = target_cursor
		else:
			var blend := clampf(delta * lerpf(30.0, 4.0, cursor_smoothness_value), 0.0, 1.0)
			grid.cursor_position = grid.cursor_position.lerp(target_cursor, blend)
		grid.refresh()
	if preview_grid != null:
		preview_grid.current_time = song_time
		preview_grid.line_preview_duration = _bar_seconds()
		preview_grid.active_layer_opacity = float(layers[current_layer].opacity)
		preview_grid.shapes = shape_list
		preview_grid.selected_shape_id = selected_shape_id
		preview_grid.animate_notes = audio_loaded
		preview_grid.approach_rate = approach_rate_value
		preview_grid.cursor_position = grid.cursor_position
		preview_grid.refresh()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		for slider in get_tree().get_nodes_in_group("workshop_sliders"):
			if not slider.get_global_rect().has_point(event.global_position):
				continue
			if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				get_viewport().set_input_as_handled()
				return
			if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				slider.value = float(slider.get_meta("workshop_default_value", slider.value))
				get_viewport().set_input_as_handled()
				return
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var focused_control := get_viewport().gui_get_focus_owner()
			if (
				focused_control is LineEdit
				and not focused_control.get_global_rect().has_point(event.global_position)
			):
				focused_control.release_focus()
		return
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	var focused := get_viewport().gui_get_focus_owner()
	var text_editing := focused is LineEdit or focused is TextEdit or focused is SpinBox
	if text_editing:
		return
	var modifier := key.ctrl_pressed or key.meta_pressed
	if key.keycode == KEY_SPACE:
		_toggle_play()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_LEFT:
		_navigate_note(-1)
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_RIGHT:
		_navigate_note(1)
		get_viewport().set_input_as_handled()
	elif (
		not modifier
		and key.keycode in [KEY_Q, KEY_W, KEY_E, KEY_A, KEY_S, KEY_D, KEY_Z, KEY_X, KEY_C]
	):
		var cell := [KEY_Q, KEY_W, KEY_E, KEY_A, KEY_S, KEY_D, KEY_Z, KEY_X, KEY_C].find(
			key.keycode
		)
		_place_keyboard_note(cell)
		get_viewport().set_input_as_handled()
	elif modifier and key.keycode == KEY_Z:
		if key.shift_pressed:
			_redo()
		else:
			_undo()
		get_viewport().set_input_as_handled()
	elif modifier and key.keycode == KEY_Y:
		_redo()
		get_viewport().set_input_as_handled()
	elif modifier and key.keycode == KEY_A:
		_select_all_in_layer()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_DELETE:
		_delete_selected()
		get_viewport().set_input_as_handled()


func _place_keyboard_note(cell: int) -> void:
	if grid == null or current_tool in ["Select", "Marker"]:
		return
	var position := Vector2((cell % 3 + 0.5) / 3.0, (floori(float(cell) / 3.0) + 0.5) / 3.0)
	_append_note(position, song_time, "Pencil")
	last_placed_position = position
	_auto_advance_playhead()
	_sync_grid()


func _navigate_note(direction: int) -> void:
	if note_list.is_empty():
		return
	var ordered := note_list.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary): return float(a.time) < float(b.time))
	var target: Dictionary = ordered[0] if direction > 0 else ordered[-1]
	if direction > 0:
		for note in ordered:
			if float(note.time) > song_time + 0.001:
				target = note
				break
	else:
		for i in range(ordered.size() - 1, -1, -1):
			if float(ordered[i].time) < song_time - 0.001:
				target = ordered[i]
				break
	selected_id = str(target.id)
	selected_ids = [selected_id]
	_seek_ratio(float(target.time) / maxf(duration, 0.01))
	_sync_grid()


func _record_history() -> void:
	if restoring_history:
		return
	while history.size() > history_index + 1:
		history.remove_at(history.size() - 1)
	history.append(
		{
			"notes": note_list.duplicate(true),
			"shapes": shape_list.duplicate(true),
			"markers": markers.duplicate(true),
			"layers": layers.duplicate(true),
			"bpm_points": bpm_points.duplicate(),
			"bpm": bpm,
			"current_layer": current_layer
		}
	)
	history_index = history.size() - 1


func _undo() -> void:
	if history_index <= 0:
		return
	history_index -= 1
	_restore_history(history[history_index])


func _redo() -> void:
	if history_index >= history.size() - 1:
		return
	history_index += 1
	_restore_history(history[history_index])


func _restore_history(state: Dictionary) -> void:
	restoring_history = true
	note_list.clear()
	for note in state.get("notes", []):
		note_list.append(note.duplicate(true))
	shape_list.clear()
	for shape in state.get("shapes", []):
		shape_list.append(shape.duplicate(true))
	markers.clear()
	for marker in state.get("markers", []):
		markers.append(marker.duplicate(true))
	layers.clear()
	for layer in state.get("layers", []):
		layers.append(layer.duplicate(true))
	if layers.is_empty():
		layers.append({"name": "Layer 1", "color": ACCENT, "visible": true, "opacity": 0.9})
	bpm_points.clear()
	for point in state.get("bpm_points", []):
		bpm_points.append(point)
	bpm = float(state.get("bpm", bpm))
	current_layer = clampi(int(state.get("current_layer", 0)), 0, layers.size() - 1)
	selected_id = ""
	selected_ids.clear()
	selected_shape_id = ""
	active_shape_id = ""
	if bpm_graph != null:
		bpm_graph.points = bpm_points.duplicate()
		bpm_graph.queue_redraw()
	if wave_overlay != null:
		wave_overlay.bpm_points = bpm_points
		wave_overlay.queue_redraw()
	restoring_history = false
	_refresh_layers()
	_sync_grid()


func _select_all_in_layer() -> void:
	selected_ids.clear()
	for note in note_list:
		if str(note.get("layer", "Layer 1")) == str(layers[current_layer].name):
			selected_ids.append(str(note.get("id", "")))
	selected_id = selected_ids.back() if not selected_ids.is_empty() else ""
	_sync_grid()


func _select_note_by_id(note_id: String) -> void:
	selected_shape_id = ""
	selected_id = note_id
	selected_ids = [note_id]
	_sync_grid()


func _delete_note_by_id(note_id: String) -> void:
	selected_id = note_id
	selected_ids = [note_id]
	_delete_selected()


func _on_grid_hovered(position: Vector2) -> void:
	if grid == null:
		return
	grid.active_layer_color = layers[current_layer].color
	grid.snap_enabled = snap_enabled
	grid.ghost_position = position if current_tool not in ["Select", "Marker"] else Vector2(-1, -1)
	grid.refresh()
	if preview_grid != null:
		preview_grid.active_layer_color = layers[current_layer].color
		preview_grid.snap_enabled = snap_enabled
		preview_grid.ghost_position = grid.ghost_position
		preview_grid.refresh()


func _build_theme() -> void:
	var theme := Theme.new()
	theme.default_font_size = 14
	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", Color.WHITE)
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", MUTED)
	theme.set_color("font_color", "OptionButton", TEXT)
	theme.set_color("font_color", "CheckBox", TEXT)
	theme.set_color("font_color", "TabBar", TEXT)
	theme.set_color("font_color", "RichTextLabel", TEXT)
	theme.set_color("font_color", "SpinBox", TEXT)
	theme.set_color("font_color", "ProgressBar", ACCENT)
	theme.set_color("font_color", "HSlider", TEXT)
	theme.set_color("font_color", "VSlider", TEXT)
	theme.set_color("font_color", "OptionButton", TEXT)
	theme.set_constant("separation", "VBoxContainer", 8)
	theme.set_constant("separation", "HBoxContainer", 8)
	get_tree().root.theme = theme
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _build_shell() -> void:
	var bg := ColorRect.new()
	bg.color = INK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var layout := HBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 0)
	add_child(layout)
	object_sidebar = _build_object_sidebar()
	object_sidebar.custom_minimum_size.x = 284
	object_sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(object_sidebar)
	app_content = VBoxContainer.new()
	app_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	app_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	app_content.add_theme_constant_override("separation", 0)
	layout.add_child(app_content)
	app_content.add_child(_build_new_topbar())
	app_content.add_child(_build_new_controls())
	var workspace := HBoxContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 0)
	app_content.add_child(workspace)
	var editor_column := VBoxContainer.new()
	editor_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor_column.add_theme_constant_override("separation", 0)
	workspace.add_child(editor_column)
	editor_column.add_child(_build_new_waveforms())
	var center := _build_center_editor()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor_column.add_child(center)
	var inspector := _build_inspector()
	inspector.custom_minimum_size.x = 330
	inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_child(inspector)
	app_content.add_child(_build_new_footer())
	_build_file_dialog()
	file_dialog.filters = PackedStringArray(["*.mp3 ; MP3 Audio"])
	file_dialog.use_native_dialog = false
	_ensure_audio_bus(music_bus_name)
	_ensure_audio_bus(hitsound_bus_name)
	_ensure_audio_bus(metronome_bus_name)
	player.bus = music_bus_name


func _build_new_topbar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = 48
	bar.add_theme_constant_override("separation", 8)
	var project_name := _line_edit("Untitled beatmap")
	project_name.text = "Untitled beatmap"
	project_name.custom_minimum_size.x = 220
	bar.add_child(project_name)
	bar.add_child(_badge("UNSAVED", Color("#e5b75c")))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	var undo_button := _button("↶", PANEL_ALT)
	undo_button.tooltip_text = "Undo · Ctrl+Z"
	undo_button.pressed.connect(_undo)
	bar.add_child(undo_button)
	var redo_button := _button("↷", PANEL_ALT)
	redo_button.tooltip_text = "Redo · Ctrl+Y"
	redo_button.pressed.connect(_redo)
	bar.add_child(redo_button)
	var divider := VSeparator.new()
	bar.add_child(divider)
	var home := _button("|◀", PANEL_ALT)
	home.tooltip_text = "Go to song start"
	home.pressed.connect(func(): _seek_ratio(0.0))
	bar.add_child(home)
	play_button = _button("▶", ACCENT)
	play_button.pressed.connect(_toggle_play)
	bar.add_child(play_button)
	var stop_button := _button("■", PANEL_ALT)
	stop_button.pressed.connect(_stop_track)
	bar.add_child(stop_button)
	var pause_button := _button("Ⅱ", PANEL_ALT)
	pause_button.pressed.connect(_pause_track)
	bar.add_child(pause_button)
	time_label = _label("00:00.000", 14, TEXT, true)
	bar.add_child(_pad(time_label, 10, 6, 0, 0))
	playback_percent_label = _label("0.0%", 12, MUTED)
	bar.add_child(playback_percent_label)
	status_label = _label("Choose an MP3 to begin", 11, MUTED)
	bar.add_child(status_label)
	var settings := _button("⚙", PANEL_ALT)
	settings.tooltip_text = "Audio and editor settings"
	settings.pressed.connect(func(): file_dialog.popup_centered_ratio(0.65))
	bar.add_child(_pad(settings, 8, 16, 0, 0))
	return bar


func _build_new_controls() -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 78
	row.add_theme_constant_override("separation", 14)
	var bpm_group := VBoxContainer.new()
	bpm_group.add_child(_label("BPM", 10, MUTED, true))
	var bpm_row := HBoxContainer.new()
	bpm_graph_button = _button("╱", ACCENT)
	bpm_graph_button.tooltip_text = "Toggle BPM chart"
	bpm_graph_button.pressed.connect(_toggle_bpm_graph)
	bpm_row.add_child(bpm_graph_button)
	bpm_value_spin = SpinBox.new()
	bpm_value_spin.min_value = 20.0
	bpm_value_spin.max_value = 500.0
	bpm_value_spin.step = 0.01
	bpm_value_spin.value = bpm
	bpm_value_spin.custom_minimum_size.x = 112
	bpm_value_spin.value_changed.connect(_on_bpm_value_changed)
	bpm_row.add_child(bpm_value_spin)
	bpm_add_button = _button("＋", PANEL_ALT)
	bpm_add_button.tooltip_text = "Add BPM point at the playhead"
	bpm_add_button.pressed.connect(_add_bpm_point_at_playhead)
	bpm_row.add_child(bpm_add_button)
	bpm_group.add_child(bpm_row)
	row.add_child(_pad(bpm_group, 8, 8, 7, 5))
	var grid_group := VBoxContainer.new()
	grid_group.add_child(_label("GRID DIVISION", 10, MUTED, true))
	var grid_row := HBoxContainer.new()
	grid_x_spin = _new_spin(1, 32, 3, 1)
	grid_y_spin = _new_spin(1, 32, 3, 1)
	grid_x_spin.value_changed.connect(
		func(value):
			grid.snap_x = int(value)
			grid.refresh()
	)
	grid_y_spin.value_changed.connect(
		func(value):
			grid.snap_y = int(value)
			grid.refresh()
	)
	grid_row.add_child(grid_x_spin)
	grid_row.add_child(_label("×", 13, MUTED))
	grid_row.add_child(grid_y_spin)
	grid_group.add_child(grid_row)
	row.add_child(_pad(grid_group, 8, 8, 7, 5))
	var beat_group := VBoxContainer.new()
	beat_group.add_child(_label("BEAT DIVISION", 10, MUTED, true))
	beat_division_option = OptionButton.new()
	for item in ["1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64"]:
		beat_division_option.add_item(item)
	beat_division_option.select(2)
	beat_division_option.item_selected.connect(_on_beat_division_selected)
	beat_group.add_child(beat_division_option)
	row.add_child(_pad(beat_group, 8, 8, 7, 5))
	var auto_group := VBoxContainer.new()
	auto_group.add_child(_label("AUTO-ADVANCE", 10, MUTED, true))
	var auto := CheckBox.new()
	auto.focus_mode = Control.FOCUS_NONE
	auto.button_pressed = false
	auto.toggled.connect(func(value): auto_advance = value)
	auto_group.add_child(auto)
	row.add_child(_pad(auto_group, 8, 8, 7, 5))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	return row


func _build_new_waveforms() -> Control:
	var wave_panel := _panel()
	waveform_panel = wave_panel
	wave_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wave_panel.custom_minimum_size.y = 116
	var columns := VBoxContainer.new()
	columns.add_theme_constant_override("separation", 1)
	wave_panel.add_child(columns)
	var mini_row := HBoxContainer.new()
	minimap = WaveformView.new()
	minimap.custom_minimum_size = Vector2(120, 20)
	minimap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	minimap.background = Color("#0d1117")
	minimap.background_bottom = Color("#0d1117")
	minimap.wave_color_top = Color("#8aa0c4")
	minimap.wave_color_bottom = Color("#42516a")
	minimap.smoothing = 2
	minimap.follow_playhead = false
	mini_overlay = SELECT_SCRIPT.new()
	mini_overlay.waveform = minimap
	mini_overlay.fit_only = true
	minimap.add_child(mini_overlay)
	minimap.seek_requested.connect(_seek_minimap_ratio)
	mini_row.add_child(minimap)
	columns.add_child(mini_row)
	waveform = WaveformView.new()
	waveform.custom_minimum_size = Vector2(300, 78)
	waveform.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	waveform.size_flags_vertical = Control.SIZE_EXPAND_FILL
	waveform.background = Color("#11151d")
	waveform.background_bottom = Color("#141a24")
	waveform.wave_color_top = Color("#8baeff")
	waveform.wave_color_bottom = Color("#3b5f9c")
	waveform.rms_color = Color("#bfd4ff", 0.7)
	waveform.smoothing = 1
	waveform.follow_playhead = false
	waveform.seek_requested.connect(_seek_ratio)
	columns.add_child(waveform)
	wave_overlay = SELECT_SCRIPT.new()
	wave_overlay.waveform = waveform
	wave_overlay.bar_seconds = _bar_seconds()
	wave_overlay.bpm_points = bpm_points
	wave_overlay.region_selected.connect(_on_wave_region_selected)
	wave_overlay.note_selected.connect(_select_note_by_id)
	wave_overlay.note_delete_requested.connect(_delete_note_by_id)
	waveform.add_child(wave_overlay)
	bpm_graph = BPM_SCRIPT.new()
	bpm_graph.waveform = waveform
	bpm_graph.points = bpm_points.duplicate()
	bpm_graph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bpm_graph.visible = false
	bpm_graph.points_changed.connect(_on_bpm_points_changed)
	waveform.add_child(bpm_graph)
	waveform.view_changed.connect(func(_start, _zoom): mini_overlay.queue_redraw())
	mini_overlay.viewport_waveform = waveform
	return wave_panel


func _build_object_sidebar() -> PanelContainer:
	var panel := _panel()
	panel.custom_minimum_size.x = 284
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	panel.add_child(root)

	var brand := HBoxContainer.new()
	brand.custom_minimum_size.y = 88
	brand.add_theme_constant_override("separation", 11)
	var logo := PanelContainer.new()
	logo.custom_minimum_size = Vector2(50, 50)
	logo.add_theme_stylebox_override("panel", _style(ACCENT, 12, ACCENT))
	logo.add_child(_label("◈", 30, Color.WHITE, true))
	brand.add_child(_pad(logo, 15, 0, 12, 12))
	brand.add_child(_label("squircle workshop", 18, TEXT, true))
	root.add_child(brand)

	var brand_tabs := HBoxContainer.new()
	brand_tabs.custom_minimum_size.y = 42
	var objects_tab := _button("Objects", PANEL_ALT)
	objects_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	objects_tab.pressed.connect(
		func():
			tree_mode = "Tree"
			_refresh_object_list()
	)
	brand_tabs.add_child(objects_tab)
	var library_tab := _button("Library", PANEL_ALT)
	library_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	library_tab.pressed.connect(
		func():
			tree_mode = "Library"
			_refresh_object_list()
	)
	brand_tabs.add_child(library_tab)
	root.add_child(brand_tabs)

	var objects_heading := HBoxContainer.new()
	objects_heading.add_child(_label("OBJECTS", 10, MUTED, true))
	var heading_spacer := Control.new()
	heading_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	objects_heading.add_child(heading_spacer)
	var filter_button := _button("☰", PANEL_ALT)
	filter_button.tooltip_text = "Filter by object type"
	objects_heading.add_child(filter_button)
	root.add_child(_pad(objects_heading, 10, 10, 5, 0))
	var search_row := HBoxContainer.new()
	search_input = _line_edit("Search")
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.text_changed.connect(func(_value): _refresh_object_list())
	search_row.add_child(search_input)
	root.add_child(_pad(search_row, 10, 10, 2, 6))
	object_filter_menu = PopupMenu.new()
	for item in ["All", "Notes", "Lines", "Curves", "Markers"]:
		object_filter_menu.add_item(item)
	object_filter_menu.id_pressed.connect(_on_object_filter_selected)
	add_child(object_filter_menu)
	filter_button.pressed.connect(
		func():
			object_filter_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i(1, 1)))
	)

	object_tree_scroll = ScrollContainer.new()
	object_tree_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(object_tree_scroll)
	tree_list = VBoxContainer.new()
	tree_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	object_tree_scroll.add_child(tree_list)
	library_scroll = ScrollContainer.new()
	library_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	library_scroll.visible = false
	root.add_child(library_scroll)
	library_list = VBoxContainer.new()
	library_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	library_scroll.add_child(library_list)
	tree_context_menu = PopupMenu.new()
	tree_context_menu.add_item("Delete", 1)
	tree_context_menu.id_pressed.connect(_on_tree_context_action)
	add_child(tree_context_menu)

	var view_panel := VBoxContainer.new()
	view_panel.add_theme_constant_override("separation", 2)
	view_panel.add_child(_label("VIEW", 10, MUTED, true))
	show_grid_check = _new_check("Show Grid", true)
	show_grid_check.toggled.connect(
		func(value):
			grid.show_grid = value
			grid.refresh()
	)
	view_panel.add_child(show_grid_check)
	show_cursor_check = _new_check("Show Cursor", true)
	show_cursor_check.toggled.connect(
		func(value):
			grid.show_cursor = value
			grid.refresh()
	)
	view_panel.add_child(show_cursor_check)
	extend_boundary_check = _new_check("Extend Grid Boundary", false)
	extend_boundary_check.toggled.connect(
		func(value):
			grid.extend_grid_boundary = value
			grid.refresh()
	)
	view_panel.add_child(extend_boundary_check)
	root.add_child(_pad(view_panel, 10, 8, 8, 7))

	var count_row := HBoxContainer.new()
	played_count_label = _label("0 / 0", 11, TEXT, true)
	count_row.add_child(_pad(played_count_label, 12, 4, 8, 8))
	selected_count_label = _label("Selected: 0", 11, ACCENT, true)
	count_row.add_child(_pad(selected_count_label, 4, 4, 8, 8))
	root.add_child(count_row)
	return panel


func _build_center_editor() -> Control:
	var root := Control.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 0)
	root.add_child(column)
	var action_row := HBoxContainer.new()
	for item in ["Select", "Rotate", "Scale", "Duplicate", "MirrorV", "MirrorH", "Eraser"]:
		var button := _icon_button(item)
		tool_buttons[item] = button
		button.pressed.connect(_on_editor_tool_pressed.bind(item))
		action_row.add_child(button)
	column.add_child(action_row)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	column.add_child(body)
	var place_tools := VBoxContainer.new()
	place_tools.custom_minimum_size.x = 38
	for item in ["Pencil", "Brush", "Line", "Path", "Curve", "Marker"]:
		var button := _icon_button(item)
		tool_buttons[item] = button
		button.pressed.connect(_set_tool.bind(item))
		place_tools.add_child(button)
	body.add_child(place_tools)
	grid_area = Control.new()
	grid_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_area.clip_contents = true
	body.add_child(grid_area)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grid_area.add_child(center)
	grid = GRID_SCRIPT.new()
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	grid.custom_minimum_size = Vector2(340, 340)
	grid.grid_clicked.connect(_on_grid_clicked)
	grid.grid_dragged.connect(_on_grid_dragged)
	grid.grid_hovered.connect(_on_grid_hovered)
	grid.note_delete_requested.connect(_delete_note_by_id)
	grid.line_completed.connect(_on_line_completed)
	grid.shape_selected.connect(_select_shape)
	grid.shape_point_edit_started.connect(func(_id): _record_history())
	grid.shape_point_changed.connect(_on_shape_point_changed)
	grid.shape_point_edit_finished.connect(_on_shape_point_edit_finished)
	grid.selection_area_selected.connect(_select_grid_area)
	center.add_child(grid)
	grid_navigator = GRID_NAV_SCRIPT.new()
	grid_navigator.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	grid_navigator.position = Vector2(-124, 12)
	grid_navigator.view_changed.connect(_on_grid_view_changed)
	grid_area.add_child(grid_navigator)
	layers_toggle = _button("LAYERS  ‹", PANEL_ALT)
	layers_toggle.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	layers_toggle.position = Vector2(-44, -42)
	layers_toggle.pressed.connect(_toggle_layers_panel)
	grid_area.add_child(layers_toggle)
	layers_panel = _build_layers_panel()
	layers_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	layers_panel.position = Vector2(-312, -192)
	layers_panel.custom_minimum_size = Vector2(300, 180)
	layers_panel.visible = true
	layers_toggle.visible = false
	grid_area.add_child(layers_panel)
	return root


func _build_inspector() -> PanelContainer:
	var panel := _panel()
	panel.custom_minimum_size.x = 330
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_label("INSPECTOR", 11, MUTED, true))
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	properties_panel = VBoxContainer.new()
	properties_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	properties_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	scroll.add_child(properties_panel)
	panel.add_child(column)
	return panel


func _build_layers_panel() -> PanelContainer:
	var panel := _panel()
	var root := VBoxContainer.new()
	var header := HBoxContainer.new()
	header.add_child(_label("LAYERS", 10, MUTED, true))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var merge := _button("⇩", PANEL_ALT)
	merge.tooltip_text = "Merge current layer down"
	merge.pressed.connect(_merge_layer)
	header.add_child(merge)
	var remove := _button("−", PANEL_ALT)
	remove.pressed.connect(_delete_layer)
	header.add_child(remove)
	var add := _button("＋", PANEL_ALT)
	add.pressed.connect(_add_layer)
	header.add_child(add)
	var collapse := _button("›", PANEL_ALT)
	collapse.pressed.connect(_toggle_layers_panel)
	header.add_child(collapse)
	root.add_child(header)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	layer_list = VBoxContainer.new()
	layer_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(layer_list)
	panel.add_child(root)
	return panel


func _build_new_footer() -> Control:
	var footer := HBoxContainer.new()
	footer.custom_minimum_size.y = 72
	footer.add_theme_constant_override("separation", 10)
	footer.add_child(_label("Playback Rate", 10, MUTED))
	playback_rate_spin = SpinBox.new()
	playback_rate_spin.min_value = 0.5
	playback_rate_spin.max_value = 2.0
	playback_rate_spin.step = 0.01
	playback_rate_spin.value = 1.0
	playback_rate_spin.suffix = "x"
	playback_rate_spin.value_changed.connect(_footer_rate_changed)
	footer.add_child(playback_rate_spin)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	music_volume_slider = _add_footer_volume(footer, "Music", 0.8, music_bus_name)
	hitsound_volume_slider = _add_footer_volume(footer, "Hitsounds", 0.7, hitsound_bus_name)
	metronome_volume_slider = _add_footer_volume(footer, "Metro", 0.0, metronome_bus_name)
	var right_spacer := Control.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(right_spacer)
	var play_track := _button("Play track", ACCENT)
	play_track.pressed.connect(_toggle_play)
	footer.add_child(_pad(play_track, 12, 16, 6, 6))
	return footer


func _new_spin(minimum: float, maximum: float, value: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.custom_minimum_size.x = 72
	return spin


func _new_check(text: String, checked: bool) -> CheckBox:
	var check := CheckBox.new()
	check.focus_mode = Control.FOCUS_NONE
	check.text = text
	check.button_pressed = checked
	return check


func _icon_button(tool: String) -> Button:
	var icons := {
		"Select": "➤",
		"Rotate": "⟳",
		"Scale": "⤢",
		"Duplicate": "▢",
		"MirrorV": "◧",
		"MirrorH": "◫",
		"Eraser": "▱",
		"Pencil": "□",
		"Brush": "▦",
		"Line": "／",
		"Path": "⌁",
		"Curve": "∿",
		"Marker": "▪"
	}
	var b := _button(str(icons.get(tool, tool)), PANEL_ALT)
	b.tooltip_text = tool
	b.custom_minimum_size = Vector2(34, 34)
	return b


func _add_footer_volume(
	parent: HBoxContainer, caption: String, initial: float, bus_name: String
) -> HSlider:
	var volume_column := VBoxContainer.new()
	volume_column.custom_minimum_size.x = 145
	volume_column.add_child(_label(caption, 10, MUTED))
	var row := HBoxContainer.new()
	row.add_child(_label("◖))", 11, MUTED))
	var slider := _new_slider()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = initial
	_set_slider_default(slider, initial)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(value): _set_bus_volume(bus_name, value))
	row.add_child(slider)
	volume_column.add_child(row)
	parent.add_child(volume_column)
	_set_bus_volume(bus_name, initial)
	return slider


func _prompt_for_startup_audio() -> void:
	if startup_audio_prompted:
		return
	startup_audio_prompted = true
	await get_tree().create_timer(0.25).timeout
	file_dialog.popup_centered_ratio(0.7)


func _on_bpm_value_changed(value: float) -> void:
	if playing:
		return
	bpm = snappedf(value, 0.01)
	if bpm_points.size() <= 2:
		bpm_points = [Vector2(0.0, bpm), Vector2(1.0, bpm)]
		if bpm_graph != null:
			bpm_graph.points = bpm_points.duplicate()
			bpm_graph.queue_redraw()
		if wave_overlay != null:
			wave_overlay.bpm_points = bpm_points
			wave_overlay.bar_seconds = _bar_seconds()
			wave_overlay.queue_redraw()
		_record_history()


func _update_bpm_display() -> void:
	if bpm_value_spin != null:
		bpm_value_spin.set_value_no_signal(bpm)
	if bpm_label != null:
		bpm_label.text = "%.2f BPM" % bpm


func _save_selection_as_pattern() -> void:
	var selected: Array[String] = selected_ids.duplicate()
	if selected.is_empty() and not selected_id.is_empty():
		selected.append(selected_id)
	if selected.is_empty():
		_toast("Select one or more notes before saving a pattern.")
		return
	var pattern_name := "Selection %02d" % (library_patterns.size() + 1)
	library_patterns.append(pattern_name)
	_refresh_object_list()
	_toast("Saved pattern: " + pattern_name)


func _add_bpm_point_at_playhead() -> void:
	if playing or duration <= 0.0 or bpm_graph == null:
		return
	var ratio := clampf(song_time / duration, 0.0, 1.0)
	var replaced := false
	for index in range(bpm_points.size()):
		if absf(bpm_points[index].x - ratio) < 0.002:
			bpm_points[index] = Vector2(ratio, bpm_value_spin.value)
			replaced = true
			break
	if not replaced:
		bpm_points.append(Vector2(ratio, bpm_value_spin.value))
	bpm_points.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
	bpm_graph.points = bpm_points.duplicate()
	bpm_graph.queue_redraw()
	wave_overlay.bpm_points = bpm_points
	wave_overlay.queue_redraw()
	_record_history()


func _on_beat_division_selected(index: int) -> void:
	var denominator := int(beat_division_option.get_item_text(index).split("/")[1])
	if wave_overlay != null:
		wave_overlay.divisions_per_bar = denominator
		wave_overlay.queue_redraw()


func _on_grid_view_changed(center: Vector2, zoom_value: float) -> void:
	if grid == null:
		return
	grid.view_center = center
	grid.view_zoom = zoom_value
	grid.refresh()


func _toggle_layers_panel() -> void:
	if layers_panel != null:
		layers_panel.visible = not layers_panel.visible
		layers_toggle.visible = not layers_panel.visible


func _on_editor_tool_pressed(tool: String) -> void:
	if tool == "Duplicate":
		_duplicate_selected()
		_set_tool("Select")
	elif tool == "MirrorV":
		for note in note_list:
			if selected_ids.has(str(note.id)) or str(note.id) == selected_id:
				note.y = 1.0 - float(note.y)
		_record_history()
		_sync_grid()
	elif tool == "MirrorH":
		for note in note_list:
			if selected_ids.has(str(note.id)) or str(note.id) == selected_id:
				note.x = 1.0 - float(note.x)
		_record_history()
		_sync_grid()
	else:
		_set_tool(tool)
		_show_properties()


func _stop_track() -> void:
	if player != null:
		player.stop()
	playing = false
	song_time = 0.0
	if waveform != null:
		waveform.playback_ratio = 0.0
	if minimap != null:
		minimap.playback_ratio = 0.0
	if time_label != null:
		time_label.text = "00:00.000  /  %s" % _format_time(duration)
	if playback_percent_label != null:
		playback_percent_label.text = "0.0%"
	_set_play_button()


func _pause_track() -> void:
	if player != null and player.playing:
		player.stream_paused = true
	playing = false
	_set_play_button()
	_update_bpm_display()


func _footer_rate_changed(value: float) -> void:
	playback_speed = value
	if player.stream != null:
		player.pitch_scale = value
	if speed_value_label != null:
		speed_value_label.text = "%.2fx" % value


func _set_bus_volume(bus_name: String, linear_value: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index >= 0:
		AudioServer.set_bus_mute(index, linear_value <= 0.0)
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(linear_value, 0.0001)))


func _ensure_audio_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, "Master")


func _on_object_filter_selected(id: int) -> void:
	var options := ["All", "Notes", "Lines", "Curves", "Markers"]
	if id >= 0 and id < options.size():
		object_filter = options[id]
		_refresh_object_list()


func _commit_layer_name(layer: Dictionary, edit: LineEdit, button: Button) -> void:
	var new_name := edit.text.strip_edges()
	if new_name.is_empty():
		new_name = "Layer"
	var old_name := str(layer.name)
	layer.name = new_name
	for note in note_list:
		if str(note.get("layer", "")) == old_name:
			note.layer = new_name
	for shape in shape_list:
		if str(shape.get("layer", "")) == old_name:
			shape.layer = new_name
	button.text = new_name
	button.visible = true
	edit.visible = false
	_record_history()
	_sync_grid()


func _build_file_dialog() -> void:
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.use_native_dialog = true
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = PackedStringArray(
		["*.wav ; WAV Audio", "*.ogg ; OGG Vorbis", "*.mp3 ; MP3 Audio"]
	)
	file_dialog.file_selected.connect(_load_audio)
	add_child(file_dialog)


func _load_audio(path: String) -> void:
	if path.is_empty():
		return
	if status_label != null:
		status_label.text = "Loading waveform…"
	var pyramid: WaveformPyramid = await loader.load_pyramid(path)
	if pyramid == null:
		if status_label != null:
			status_label.text = "Could not load audio: " + loader.last_error
		return
	var stream := WaveformBaker.load_audio_stream(path)
	if stream == null:
		if status_label != null:
			status_label.text = "Could not open audio stream: " + path.get_file()
		return
	waveform.pyramid = pyramid
	minimap.pyramid = pyramid
	file_path = path
	audio_loaded = true
	player.stream = stream
	duration = stream.get_length()
	player.pitch_scale = playback_speed
	if status_label != null:
		status_label.text = (
			"%s · %.2fs · waveform %s" % [path.get_file(), duration, loader.last_source]
		)


func _toggle_play() -> void:
	if player.stream == null:
		return
	if player.playing:
		player.stream_paused = true
		playing = false
	else:
		if player.stream_paused:
			player.stream_paused = false
		else:
			player.play(song_time)
		playing = true
	_set_play_button()


func _set_play_button() -> void:
	if play_button != null:
		play_button.text = "❚❚" if playing else "▶"


func _seek_minimap_ratio(ratio: float) -> void:
	_seek_ratio(ratio)
	if waveform == null or duration <= 0.0:
		return
	var visible_span := 1.0 / maxf(waveform.zoom, 1.0)
	waveform.set_view(ratio - visible_span * 0.5)


func _seek_ratio(ratio: float) -> void:
	if duration <= 0.0:
		return
	song_time = clampf(ratio, 0.0, 1.0) * duration
	waveform.playback_ratio = clampf(song_time / maxf(duration, 0.01), 0.0, 1.0)
	minimap.playback_ratio = waveform.playback_ratio
	if time_label != null:
		time_label.text = "%s  /  %s" % [_format_time(song_time), _format_time(duration)]
	if scrub_slider != null:
		scrub_slider.set_value_no_signal(100.0 * song_time / maxf(duration, 0.01))
	if timeline_progress != null:
		timeline_progress.value = 100.0 * song_time / maxf(duration, 0.01)
	if player.stream != null:
		var resume := playing
		player.play(song_time)
		if not resume:
			player.stream_paused = true
	playing = player.playing and not player.stream_paused
	_set_play_button()


func _select_grid_area(from: Vector2, to: Vector2) -> void:
	var bounds := Rect2(from, to - from).abs()
	selected_ids.clear()
	selected_shape_id = ""
	var approach_window := 2.4 / maxf(approach_rate_value, 0.2)
	for note in note_list:
		var layer_name := str(note.get("layer", "Layer 1"))
		if not bool(grid.visible_layers.get(layer_name, true)):
			continue
		if audio_loaded:
			var arrival := float(note.get("time", 0.0)) - song_time
			if arrival < 0.0 or arrival > approach_window:
				continue
		var position := Vector2(float(note.get("x", 0.5)), float(note.get("y", 0.5)))
		if bounds.has_point(position):
			selected_ids.append(str(note.get("id", "")))
	selected_id = selected_ids.back() if not selected_ids.is_empty() else ""
	_sync_grid()


func _on_grid_clicked(position: Vector2, control_held: bool = false) -> void:
	if current_tool == "Select":
		var nearest := ""
		var best := 0.10
		var approach_window := 2.4 / maxf(approach_rate_value, 0.2)
		for n in note_list:
			var layer_name := str(n.get("layer", "Layer 1"))
			if not bool(grid.visible_layers.get(layer_name, true)):
				continue
			if audio_loaded:
				var arrival := float(n.get("time", 0.0)) - song_time
				if arrival < 0.0 or arrival > approach_window:
					continue
			var d := position.distance_to(Vector2(float(n.x), float(n.y)))
			if d < best:
				best = d
				nearest = str(n.id)
		if nearest != "":
			selected_shape_id = ""
			if control_held:
				if selected_ids.has(nearest):
					selected_ids.erase(nearest)
				else:
					selected_ids.append(nearest)
				selected_id = selected_ids.back() if not selected_ids.is_empty() else ""
			else:
				selected_id = nearest
				selected_ids = [nearest]
		else:
			selected_id = ""
			selected_ids.clear()
			selected_shape_id = ""
		_show_properties()
		_sync_grid()
		return
	if current_tool == "Marker":
		_add_marker_at_time(song_time)
		_toast("Marker added at %s" % _format_time(song_time))
		return
	if current_tool in ["Path", "Curve"]:
		_add_shape_control_point(position, current_tool)
		return
	var x := position.x
	var y := position.y
	if snap_enabled and not Input.is_key_pressed(KEY_SHIFT):
		x = (
			(round(x * grid.snap_x - grid.grid_offset.x - 0.5) + grid.grid_offset.x + 0.5)
			/ float(grid.snap_x)
		)
		y = (
			(round(y * grid.snap_y - grid.grid_offset.y - 0.5) + grid.grid_offset.y + 0.5)
			/ float(grid.snap_y)
		)
		x = clampf(x, 0.03, 0.97)
		y = clampf(y, 0.03, 0.97)
	if current_tool == "Brush":
		brush_notes_placed = 1
		last_brush_position = Vector2(x, y)
		_append_note(Vector2(x, y), song_time, "Brush")
	else:
		_append_note(Vector2(x, y), song_time, current_tool)
	last_placed_position = Vector2(x, y)
	_auto_advance_playhead()
	_refresh_object_list()
	_show_properties()
	_sync_grid()


func _add_marker_at_time(at_time: float) -> void:
	selected_shape_id = ""
	markers.append(
		{
			"id": str(Time.get_ticks_usec()),
			"name": "Marker %02d" % (markers.size() + 1),
			"time": at_time,
			"color": Color("#e6c45e"),
			"description": ""
		}
	)
	selected_id = str(markers[-1].id)
	selected_ids.clear()
	_record_history()
	_refresh_object_list()
	_show_properties()


func _on_grid_dragged(position: Vector2) -> void:
	if current_tool != "Brush":
		return
	var snapped := position
	if snap_enabled and not Input.is_key_pressed(KEY_SHIFT):
		snapped.x = (
			(round(snapped.x * grid.snap_x - grid.grid_offset.x - 0.5) + grid.grid_offset.x + 0.5)
			/ float(grid.snap_x)
		)
		snapped.y = (
			(round(snapped.y * grid.snap_y - grid.grid_offset.y - 0.5) + grid.grid_offset.y + 0.5)
			/ float(grid.snap_y)
		)
	if snapped.distance_to(last_brush_position) < 0.08:
		return
	last_brush_position = snapped
	var at_time := song_time + brush_notes_placed * _bar_seconds() / 4.0
	brush_notes_placed += 1
	_append_note(snapped, at_time, "Brush")
	_sync_grid()


func _append_note(
	position: Vector2, at_time: float, note_type: String, record: bool = true
) -> void:
	selected_shape_id = ""
	var new_note := {
		"id": str(Time.get_ticks_usec() + note_list.size()),
		"x": clampf(position.x, 0.02, 0.98),
		"y": clampf(position.y, 0.02, 0.98),
		"time": at_time,
		"bar": _time_to_bar(at_time),
		"name": "Note %02d" % (note_list.size() + 1),
		"layer": str(layers[current_layer].name),
		"type": note_type
	}
	note_list.append(new_note)
	selected_id = str(new_note.id)
	selected_ids = [selected_id]
	if record:
		_record_history()


func _auto_advance_playhead() -> void:
	if not auto_advance:
		return
	song_time = minf(song_time + _bar_seconds(), maxf(duration, 0.0))
	_seek_ratio(song_time / maxf(duration, 0.01))
	_play_advance_cue(song_time)


func _on_line_completed(start: Vector2, finish: Vector2) -> void:
	var shape_id := str(Time.get_ticks_usec())
	shape_list.append(
		{
			"id": shape_id,
			"type": "Line",
			"points": [_snap_grid_position(start), _snap_grid_position(finish)],
			"time": song_time,
			"duration": _bar_seconds(),
			"layer": str(layers[current_layer].name)
		}
	)
	selected_id = shape_id
	selected_ids = [shape_id]
	selected_shape_id = shape_id
	active_shape_id = ""
	_record_history()
	last_placed_position = _snap_grid_position(finish)
	_auto_advance_playhead()
	_sync_grid()


func _add_shape_control_point(position: Vector2, shape_type: String) -> void:
	var point := _snap_grid_position(position)
	var shape_index := -1
	for index in range(shape_list.size()):
		if str(shape_list[index].get("id", "")) == active_shape_id:
			shape_index = index
			break
	if shape_index < 0:
		active_shape_id = str(Time.get_ticks_usec())
		shape_list.append(
			{
				"id": active_shape_id,
				"type": shape_type,
				"points": [point],
				"time": song_time,
				"duration": _bar_seconds(),
				"layer": str(layers[current_layer].name)
			}
		)
		if auto_advance:
			_auto_advance_playhead()
	else:
		shape_list[shape_index].points.append(point)
	selected_id = active_shape_id
	selected_ids = [active_shape_id]
	selected_shape_id = active_shape_id
	_record_history()
	_sync_grid()


func _select_shape(shape_id: String) -> void:
	selected_id = shape_id
	selected_ids = [shape_id]
	selected_shape_id = shape_id
	_show_properties()
	_sync_grid()


func _on_shape_point_changed(shape_id: String, point_index: int, position: Vector2) -> void:
	for shape in shape_list:
		if str(shape.get("id", "")) != shape_id:
			continue
		var points: Array = shape.get("points", [])
		if point_index >= 0 and point_index < points.size():
			points[point_index] = _snap_grid_position(position)
			shape.points = points
		break
	if grid != null:
		grid.shapes = shape_list
		grid.refresh()
	if preview_grid != null:
		preview_grid.shapes = shape_list
		preview_grid.refresh()


func _on_shape_point_edit_finished(_shape_id: String) -> void:
	_record_history()
	_sync_grid()


func _snap_grid_position(position: Vector2) -> Vector2:
	var snapped := position
	if snap_enabled and not Input.is_key_pressed(KEY_SHIFT):
		snapped.x = (
			(round(snapped.x * grid.snap_x - grid.grid_offset.x - 0.5) + grid.grid_offset.x + 0.5)
			/ float(grid.snap_x)
		)
		snapped.y = (
			(round(snapped.y * grid.snap_y - grid.grid_offset.y - 0.5) + grid.grid_offset.y + 0.5)
			/ float(grid.snap_y)
		)
	return Vector2(clampf(snapped.x, 0.02, 0.98), clampf(snapped.y, 0.02, 0.98))


func _set_tool(tool: String) -> void:
	if tool != current_tool:
		active_shape_id = ""
	current_tool = tool
	if grid != null:
		grid.active_tool = tool
		grid.cancel_line_preview()
	if preview_grid != null:
		preview_grid.active_tool = tool
		preview_grid.cancel_line_preview()
	for name in tool_buttons:
		var button: Button = tool_buttons[name]
		var border := Color.WHITE if name == tool else BORDER
		button.add_theme_stylebox_override("normal", _style(PANEL_ALT, 8, border))
	_toast("%s tool selected" % tool)


func _toggle_bpm_graph() -> void:
	bpm_graph_open = not bpm_graph_open
	if bpm_graph != null:
		bpm_graph.visible = bpm_graph_open
	_toast("BPM automation: click to add points · drag to adjust")


func _on_bpm_points_changed(points: Array) -> void:
	var snapshot: Array[Vector2] = []
	for point in points.duplicate():
		snapshot.append(point)
	bpm_points = snapshot
	if wave_overlay != null:
		wave_overlay.bpm_points = bpm_points
		wave_overlay.queue_redraw()
	if not bpm_points.is_empty():
		bpm = bpm_points[0].y
		_update_bpm_display()
		_toast("BPM automation · %.2f BPM at start" % bpm)
	_record_history()


func _on_wave_region_selected(from_ratio: float, to_ratio: float) -> void:
	selected_id = ""
	selected_ids.clear()
	var count := 0
	for note in note_list:
		var ratio := float(note.time) / maxf(duration, 0.01)
		if ratio >= from_ratio and ratio <= to_ratio:
			selected_id = str(note.id)
			selected_ids.append(selected_id)
			count += 1
	_sync_grid()
	_toast("Selected time range · %d notes" % count)


func _set_tree_mode(mode: String) -> void:
	tree_mode = mode
	_refresh_object_list()


func _refresh_object_list() -> void:
	if tree_list == null or library_list == null:
		return
	for child in tree_list.get_children():
		child.queue_free()
	for child in library_list.get_children():
		child.queue_free()
	tree_list.visible = tree_mode == "Tree"
	library_list.visible = tree_mode == "Library"
	if object_tree_scroll != null:
		object_tree_scroll.visible = tree_mode == "Tree"
	if library_scroll != null:
		library_scroll.visible = tree_mode == "Library"
	if tree_mode == "Library":
		for pattern in library_patterns:
			var pattern_id := "library:" + pattern
			var button := _button("▦  " + pattern, PANEL_ALT)
			button.pressed.connect(func(): _place_pattern())
			button.gui_input.connect(
				func(event):
					if (
						event is InputEventMouseButton
						and event.button_index == MOUSE_BUTTON_RIGHT
						and event.pressed
					):
						tree_context_item_id = pattern_id
						tree_context_menu.position = Vector2i(get_global_mouse_position())
						tree_context_menu.popup()
						button.accept_event()
			)
			library_list.add_child(button)
		var save_button := _button("＋ Save selection as pattern", PANEL_ALT)
		save_button.pressed.connect(func(): _save_selection_as_pattern())
		library_list.add_child(save_button)
		return
	var query := search_input.text.to_lower() if search_input != null else ""
	var show_notes := object_filter in ["All", "Notes"]
	if show_notes:
		var notes_by_bar: Dictionary = {}
		for note in note_list:
			var bar_number := maxi(int(floor(float(note.get("bar", 1.0)))), 1)
			if not notes_by_bar.has(bar_number):
				notes_by_bar[bar_number] = []
			if (
				query == ""
				or ("note %d" % bar_number).contains(query)
				or str(note.get("name", note.get("type", "Note"))).to_lower().contains(query)
			):
				notes_by_bar[bar_number].append(note)
		var bars: Array = notes_by_bar.keys()
		bars.sort()
		for bar_number in bars:
			var group_key := "bar:%d" % int(bar_number)
			var header := _button(
				(
					("▾ " if expanded_note_groups.get(group_key, true) else "▸ ")
					+ "Bar %02d" % int(bar_number)
				),
				INK
			)
			header.alignment = HORIZONTAL_ALIGNMENT_LEFT
			header.pressed.connect(
				func():
					expanded_note_groups[group_key] = not expanded_note_groups.get(group_key, true)
					_refresh_object_list()
			)
			tree_list.add_child(header)
			if not expanded_note_groups.get(group_key, true):
				continue
			for note in notes_by_bar[bar_number]:
				var note_id := str(note.get("id", ""))
				var note_time := float(note.get("time", 0.0))
				var note_number := note_list.find(note) + 1
				var note_title := str(note.get("name", "Note %02d" % maxi(note_number, 1)))
				_add_tree_item(
					note_id,
					"□",
					note_title,
					note_time,
					ACCENT,
					query,
					func():
						selected_id = note_id
						selected_ids = [note_id]
						selected_shape_id = ""
						_seek_ratio(note_time / maxf(duration, 0.01))
						_sync_grid()
				)
	if object_filter in ["All", "Lines", "Curves"]:
		for shape in shape_list:
			var shape_id := str(shape.get("id", ""))
			var shape_type := str(shape.get("type", "Shape"))
			if object_filter != "All" and object_filter != shape_type + "s":
				continue
			_add_tree_item(
				shape_id,
				"⌁",
				shape_type,
				float(shape.get("time", 0.0)),
				CYAN,
				query,
				func(): _select_shape(shape_id)
			)
	if object_filter in ["All", "Markers"] and not markers.is_empty():
		var bookmarks_header := _label("BOOKMARKS", 9, MUTED, true)
		tree_list.add_child(bookmarks_header)
		for item in markers:
			var marker_id := str(item.get("id", ""))
			_add_tree_item(
				marker_id,
				"◆",
				str(item.get("name", "Bookmark")),
				float(item.get("time", 0.0)),
				item.get("color", Color("#e6c45e")),
				query,
				func():
					selected_shape_id = ""
					selected_id = marker_id
					selected_ids.clear()
					_seek_ratio(float(item.get("time", 0.0)) / maxf(duration, 0.01))
					_show_properties()
			)
	if tree_list.get_child_count() == 0:
		tree_list.add_child(_label("No matching objects yet.", 11, MUTED))


func _add_tree_item(
	object_id: String,
	icon: String,
	name: String,
	time: float,
	color: Color,
	query: String,
	action: Callable
) -> void:
	if query != "" and not name.to_lower().contains(query):
		return
	var row := HBoxContainer.new()
	var button := _button(icon + "  " + name, PANEL_ALT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(action)
	if object_id == selected_id or object_id == selected_shape_id or selected_ids.has(object_id):
		button.add_theme_stylebox_override("normal", _style(PANEL_ALT, 7, Color.WHITE))
	button.gui_input.connect(
		func(event):
			if (
				event is InputEventMouseButton
				and event.button_index == MOUSE_BUTTON_RIGHT
				and event.pressed
			):
				tree_context_item_id = object_id
				tree_context_menu.position = Vector2i(get_global_mouse_position())
				tree_context_menu.popup()
				button.accept_event()
	)
	row.add_child(button)
	button.tooltip_text = "%s · %s" % [_format_time(time), color.to_html()]
	button.text += "  ·  " + _format_time(time)
	tree_list.add_child(row)


func _on_tree_context_action(action_id: int) -> void:
	if action_id != 1 or tree_context_item_id.is_empty():
		return
	if tree_context_item_id.begins_with("library:"):
		library_patterns.erase(tree_context_item_id.trim_prefix("library:"))
		tree_context_item_id = ""
		_refresh_object_list()
		return
	for index in range(markers.size() - 1, -1, -1):
		if str(markers[index].get("id", "")) == tree_context_item_id:
			markers.remove_at(index)
			break
	for index in range(shape_list.size() - 1, -1, -1):
		if str(shape_list[index].get("id", "")) == tree_context_item_id:
			shape_list.remove_at(index)
			break
	if selected_id == tree_context_item_id:
		selected_id = ""
		selected_ids.clear()
		selected_shape_id = ""
	if active_shape_id == tree_context_item_id:
		active_shape_id = ""
	tree_context_item_id = ""
	_record_history()
	_refresh_object_list()
	_sync_grid()


func _show_properties() -> void:
	if properties_panel == null:
		return
	for child in properties_panel.get_children():
		child.queue_free()
	properties_panel.add_child(_section_title("Selected object", "PROPERTIES"))
	for shape in shape_list:
		if str(shape.get("id", "")) == selected_shape_id:
			properties_panel.add_child(
				_label(
					"Editable %s · %d control points" % [str(shape.type), shape.points.size()],
					11,
					CYAN,
					true
				)
			)
			properties_panel.add_child(
				_label("Drag the yellow control points on the playfield to edit.", 10, MUTED)
			)
			return
	var selected: Dictionary = {}
	for n in note_list:
		if str(n.id) == selected_id:
			selected = n
			break
	if selected.is_empty():
		for marker in markers:
			if str(marker.get("id", "")) == selected_id:
				_build_bookmark_properties(marker, "Marker")
				return
		properties_panel.add_child(
			_label("Select a note or marker to edit its properties.", 11, MUTED)
		)
		return
	var header := HBoxContainer.new()
	header.add_child(_label("● Note", 12, ACCENT, true))
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_spacer)
	var duplicate_button := _button("Duplicate", PANEL_ALT)
	duplicate_button.pressed.connect(_duplicate_selected)
	header.add_child(duplicate_button)
	var delete_button := _button("Delete", PANEL_ALT)
	delete_button.pressed.connect(_delete_selected)
	header.add_child(delete_button)
	properties_panel.add_child(header)

	var note_index := note_list.find(selected) + 1
	var name_input := _line_edit("Note name")
	name_input.text = str(selected.get("name", "Note %02d" % maxi(note_index, 1)))
	name_input.text_changed.connect(
		func(value):
			selected.name = value
			_record_history()
			_refresh_object_list()
	)
	properties_panel.add_child(_field("Name", name_input))

	var time_control := _property_spin(
		"Time (s)",
		float(selected.time),
		0.0,
		maxf(duration, 999.0),
		0.001,
		func(value):
			selected.time = value
			selected.bar = _time_to_bar(value)
			_record_history()
			_refresh_object_list()
			if grid != null:
				grid.refresh()
			if wave_overlay != null:
				wave_overlay.queue_redraw()
	)
	properties_panel.add_child(time_control)
	properties_panel.add_child(
		_label("Bar %.3f · %s" % [float(selected.bar), str(selected.layer)], 10, MUTED)
	)

	var position_row := HBoxContainer.new()
	position_row.add_theme_constant_override("separation", 8)
	var x_control := _property_spin(
		"X",
		float(selected.x),
		0.0,
		1.0,
		0.01,
		Callable(self, "_on_selected_note_position_changed").bind("x", selected)
	)
	var y_control := _property_spin(
		"Y",
		float(selected.y),
		0.0,
		1.0,
		0.01,
		Callable(self, "_on_selected_note_position_changed").bind("y", selected)
	)
	position_row.add_child(x_control)
	position_row.add_child(y_control)
	properties_panel.add_child(position_row)

	var layer_option := OptionButton.new()
	layer_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var selected_layer_index := 0
	for layer_index in range(layers.size()):
		layer_option.add_item(str(layers[layer_index].name))
		if str(layers[layer_index].name) == str(selected.get("layer", "Layer 1")):
			selected_layer_index = layer_index
	layer_option.select(selected_layer_index)
	layer_option.item_selected.connect(
		func(index):
			selected.layer = str(layers[index].name)
			_record_history()
			_sync_grid()
	)
	properties_panel.add_child(_field("Layer", layer_option))

	var rotate_row := HBoxContainer.new()
	var angle := SpinBox.new()
	angle.min_value = -360.0
	angle.max_value = 360.0
	angle.value = 15.0
	angle.prefix = "Rotate ° "
	angle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rotate_row.add_child(angle)
	var rotate_button := _button("Apply", PANEL_ALT)
	rotate_button.pressed.connect(func(): _transform_selected(angle.value, 1.0, false))
	rotate_row.add_child(rotate_button)
	properties_panel.add_child(rotate_row)

	var scale_row := HBoxContainer.new()
	var scale_input := SpinBox.new()
	scale_input.min_value = 0.1
	scale_input.max_value = 4.0
	scale_input.step = 0.1
	scale_input.value = 1.1
	scale_input.prefix = "Scale × "
	scale_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scale_row.add_child(scale_input)
	var scale_button := _button("Apply", PANEL_ALT)
	scale_button.pressed.connect(func(): _transform_selected(0.0, scale_input.value, false))
	scale_row.add_child(scale_button)
	properties_panel.add_child(scale_row)
	var reverse_button := _button("Reverse time", PANEL_ALT)
	reverse_button.pressed.connect(func(): _transform_selected(0.0, 1.0, true))
	properties_panel.add_child(reverse_button)


func _on_selected_note_position_changed(value: float, axis: String, note: Dictionary) -> void:
	note[axis] = value
	_record_history()
	if grid != null:
		grid.refresh()
	if wave_overlay != null:
		wave_overlay.queue_redraw()


func _build_bookmark_properties(item: Dictionary, kind: String) -> void:
	properties_panel.add_child(_label("◆ " + kind, 12, Color("#e6c45e"), true))
	var name_input := _line_edit("Name")
	name_input.text = str(item.get("name", kind))
	name_input.text_changed.connect(
		func(value):
			item.name = value
			_record_history()
			_refresh_object_list()
	)
	properties_panel.add_child(_field(kind + " name", name_input))
	var time_input := _property_spin(
		"Time (s)",
		float(item.get("time", 0.0)),
		0,
		maxf(duration, 999),
		0.001,
		func(value):
			item.time = value
			_record_history()
			_refresh_object_list()
	)
	properties_panel.add_child(time_input)
	var description := _line_edit("Add a note to return to later…")
	description.text = str(item.get("description", ""))
	description.text_changed.connect(
		func(value):
			item.description = value
			_record_history()
	)
	properties_panel.add_child(_field("Description", description))
	var color_picker := ColorPickerButton.new()
	color_picker.color = item.get("color", Color("#e6c45e"))
	color_picker.color_changed.connect(
		func(value):
			item.color = value
			_record_history()
			if wave_overlay != null:
				wave_overlay.queue_redraw()
	)
	properties_panel.add_child(_field("Marker color", color_picker))


func _transform_selected(degrees: float, scale_factor: float, reverse_time: bool) -> void:
	var selected: Array[Dictionary] = []
	for note in note_list:
		if (
			selected_ids.has(str(note.id))
			or (selected_ids.is_empty() and str(note.id) == selected_id)
		):
			selected.append(note)
	if selected.is_empty():
		return
	if reverse_time:
		var min_time := INF
		var max_time := -INF
		for note in selected:
			min_time = minf(min_time, float(note.time))
			max_time = maxf(max_time, float(note.time))
		for note in selected:
			note.time = min_time + max_time - float(note.time)
			note.bar = _time_to_bar(float(note.time))
	else:
		for note in selected:
			var point := (
				(
					(Vector2(float(note.x), float(note.y)) - Vector2(0.5, 0.5)).rotated(
						deg_to_rad(degrees)
					)
					* scale_factor
				)
				+ Vector2(0.5, 0.5)
			)
			note.x = clampf(point.x, 0.0, 1.0)
			note.y = clampf(point.y, 0.0, 1.0)
	_record_history()
	_sync_grid()


func _refresh_layers() -> void:
	if layer_list == null:
		return
	for child in layer_list.get_children():
		child.queue_free()
	for i in range(layers.size()):
		var layer: Dictionary = layers[i]
		var row := HBoxContainer.new()
		var eye := _button("◉" if layer.visible else "○", PANEL_ALT)
		eye.pressed.connect(
			func():
				layer.visible = not layer.visible
				_record_history()
				_refresh_layers()
				_sync_grid()
		)
		row.add_child(eye)
		var name_button := _button(str(layer.name), PANEL_ALT)
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.add_theme_stylebox_override(
			"normal", _style(PANEL_ALT, 8, Color.WHITE if i == current_layer else BORDER)
		)
		name_button.pressed.connect(_select_layer.bind(i))
		row.add_child(name_button)
		var color_btn := ColorPickerButton.new()
		color_btn.color = layer.color
		color_btn.custom_minimum_size = Vector2(30, 24)
		color_btn.color_changed.connect(
			func(c):
				layer.color = c
				_record_history()
				_sync_grid()
		)
		row.add_child(color_btn)
		var rename := _button("✎", PANEL_ALT)
		rename.tooltip_text = "Rename layer"
		rename.pressed.connect(func(): _rename_layer(layer))
		row.add_child(rename)
		var settings := _button("⚙", PANEL_ALT)
		settings.pressed.connect(func(): _open_layer_settings(layer))
		row.add_child(settings)
		layer_list.add_child(row)


func _rename_layer(layer: Dictionary) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Rename layer"
	var edit := _line_edit("Layer name")
	edit.text = str(layer.get("name", "Layer"))
	dialog.add_child(edit)
	dialog.confirmed.connect(
		func():
			_commit_layer_name(layer, edit, _button("", PANEL_ALT))
			_refresh_layers()
	)
	add_child(dialog)
	dialog.popup_centered(Vector2i(360, 130))


func _open_layer_settings(layer: Dictionary) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Layer settings · %s" % str(layer.name)
	dialog.dialog_text = "Choose the layer opacity. Color is changed from the swatch."
	var slider := _new_slider()
	slider.min_value = 0.1
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(layer.opacity)
	_set_slider_default(slider, 0.9)
	slider.value_changed.connect(
		func(value):
			layer.opacity = value
			_record_history()
			_sync_grid()
	)
	dialog.add_child(slider)
	add_child(dialog)
	dialog.popup_centered(Vector2i(360, 160))


func _duplicate_selected() -> void:
	var source: Dictionary = {}
	for note in note_list:
		if str(note.id) == selected_id:
			source = note
			break
	if source.is_empty():
		return
	var copy: Dictionary = source.duplicate(true)
	copy.id = str(Time.get_ticks_usec())
	copy.time = float(copy.time) + _bar_seconds() / 4.0
	copy.bar = _time_to_bar(float(copy.time))
	note_list.append(copy)
	selected_id = str(copy.id)
	selected_ids = [selected_id]
	_record_history()
	_sync_grid()


func _delete_selected() -> void:
	var remove_ids := selected_ids.duplicate()
	if remove_ids.is_empty():
		remove_ids.append(selected_id)
	var did_remove := false
	for i in range(note_list.size() - 1, -1, -1):
		if remove_ids.has(str(note_list[i].id)):
			note_list.remove_at(i)
			did_remove = true
	if not did_remove:
		return
	selected_id = ""
	selected_ids.clear()
	_record_history()
	_sync_grid()


func _sync_grid() -> void:
	if grid == null:
		return
	grid.notes = note_list
	grid.shapes = shape_list
	grid.selected_id = selected_id
	grid.selected_shape_id = selected_shape_id
	grid.selected_ids = selected_ids
	grid.visible_layers.clear()
	grid.layer_colors.clear()
	grid.layer_opacities.clear()
	grid.active_layer_color = layers[current_layer].color
	for layer in layers:
		grid.visible_layers[layer.name] = layer.visible
		grid.layer_colors[layer.name] = layer.color
		grid.layer_opacities[layer.name] = layer.opacity
	grid.show_grid = show_grid_check.button_pressed if show_grid_check != null else true
	grid.show_cursor = show_cursor_check.button_pressed if show_cursor_check != null else true
	grid.extend_grid_boundary = (
		extend_boundary_check.button_pressed if extend_boundary_check != null else false
	)
	if selected_count_label != null:
		var selected_count := selected_ids.size()
		if selected_count == 0 and not selected_id.is_empty():
			selected_count = 1
		if not selected_shape_id.is_empty():
			selected_count = 1
		selected_count_label.text = "Selected: %d" % selected_count
	grid.refresh()
	if wave_overlay != null:
		wave_overlay.notes = note_list
		wave_overlay.markers = markers
		wave_overlay.selected_ids = selected_ids
		wave_overlay.visible_layers = grid.visible_layers
		wave_overlay.layer_colors = grid.layer_colors
		wave_overlay.layer_opacities = grid.layer_opacities
		wave_overlay.queue_redraw()
	if mini_overlay != null:
		mini_overlay.notes = note_list
		mini_overlay.markers = markers
		mini_overlay.duration = maxf(duration, 0.01)
		mini_overlay.visible_layers = grid.visible_layers
		mini_overlay.layer_colors = grid.layer_colors
		mini_overlay.layer_opacities = grid.layer_opacities
		mini_overlay.queue_redraw()
	if preview_grid != null:
		preview_grid.notes = note_list
		preview_grid.shapes = shape_list
		preview_grid.selected_id = selected_id
		preview_grid.selected_shape_id = selected_shape_id
		preview_grid.selected_ids = selected_ids
		for layer in layers:
			preview_grid.visible_layers[layer.name] = layer.visible
			preview_grid.layer_colors[layer.name] = layer.color
			preview_grid.layer_opacities[layer.name] = layer.opacity
		preview_grid.cursor_position = grid.cursor_position
		preview_grid.refresh()
	_refresh_object_list()
	_show_properties()
	if notes_count_label != null:
		notes_count_label.text = "%d notes" % note_list.size()


func _add_layer() -> void:
	layers.append(
		{
			"name": "Layer %d" % (layers.size() + 1),
			"color": Color.from_hsv(randf(), 0.55, 0.95),
			"visible": true,
			"opacity": 0.9
		}
	)
	current_layer = layers.size() - 1
	_record_history()
	_refresh_layers()
	_sync_grid()


func _select_layer(index: int) -> void:
	current_layer = clampi(index, 0, layers.size() - 1)
	_refresh_layers()
	_sync_grid()


func _merge_layer() -> void:
	if current_layer <= 0:
		_toast("There is no layer below this one to merge into.")
		return
	var source_name := str(layers[current_layer].name)
	var target_name := str(layers[current_layer - 1].name)
	for note in note_list:
		if str(note.layer) == source_name:
			note.layer = target_name
	for shape in shape_list:
		if str(shape.get("layer", "")) == source_name:
			shape.layer = target_name
	layers.remove_at(current_layer)
	current_layer -= 1
	_record_history()
	_refresh_layers()
	_sync_grid()


func _delete_layer() -> void:
	if layers.size() <= 1:
		_toast("A beatmap needs at least one layer.")
		return
	var removed := str(layers[current_layer].name)
	layers.remove_at(current_layer)
	current_layer = clampi(current_layer - 1, 0, layers.size() - 1)
	for n in note_list:
		if str(n.layer) == removed:
			n.layer = str(layers[current_layer].name)
	for shape in shape_list:
		if str(shape.get("layer", "")) == removed:
			shape.layer = str(layers[current_layer].name)
	_record_history()
	_refresh_layers()
	_sync_grid()


func _place_pattern() -> void:
	for i in range(3):
		note_list.append(
			{
				"id": str(Time.get_ticks_usec() + i),
				"x": 0.2 + i * 0.3,
				"y": 0.25 + (i % 2) * 0.45,
				"time": song_time + i * _bar_seconds() / 2.0,
				"bar": _time_to_bar(song_time) + i * 0.5,
				"layer": str(layers[current_layer].name),
				"type": "Pattern"
			}
		)
	_record_history()
	_refresh_object_list()
	_sync_grid()


func _cursor_for_time(time: float) -> Vector2:
	var nearest: Dictionary = {}
	var best := 999999.0
	for n in note_list:
		var distance := absf(float(n.time) - time)
		if distance < best:
			best = distance
			nearest = n
	return (
		Vector2(float(nearest.get("x", 0.5)), float(nearest.get("y", 0.5)))
		if not nearest.is_empty()
		else Vector2(0.5, 0.5)
	)


func _time_to_bar(time: float) -> float:
	return time / maxf(_bar_seconds(), 0.001) + 1.0


func _bar_seconds() -> float:
	return 240.0 / maxf(bpm, 1.0)


func _property_spin(
	caption: String, value: float, minimum: float, maximum: float, step: float, callback: Callable
) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_label(caption, 9, MUTED))
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.value_changed.connect(callback)
	box.add_child(spin)
	return box


func _field(caption: String, control: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_label(caption, 10, MUTED, true))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(control)
	return box


func _section_title(title: String, kicker: String) -> Control:
	var col := VBoxContainer.new()
	col.add_child(_label(kicker, 9, ACCENT, true))
	col.add_child(_label(title, 18, TEXT, true))
	return col


func _new_slider() -> HSlider:
	var slider := SLIDER_SCRIPT.new() as HSlider
	slider.add_to_group("workshop_sliders")
	return slider


func _set_slider_default(slider: HSlider, value: float) -> void:
	slider.set_meta("workshop_default_value", value)


func _button(text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", _style(color, 8, BORDER))
	b.add_theme_stylebox_override(
		"hover", _style(Color(color).lightened(0.10), 8, Color("#536074"))
	)
	b.add_theme_stylebox_override("pressed", _style(Color(color).darkened(0.12), 8, ACCENT))
	b.add_theme_stylebox_override("focus", _style(color, 8, ACCENT))
	b.add_theme_constant_override("outline_size", 0)
	b.custom_minimum_size.y = 30
	return b


func _line_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.add_theme_stylebox_override("normal", _style(Color("#0e1116"), 6, BORDER))
	edit.add_theme_stylebox_override("focus", _style(Color("#0e1116"), 6, ACCENT))
	edit.custom_minimum_size.y = 34
	return edit


func _label(text: String, size: int = 12, color: Color = TEXT, bold: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if bold:
		label.add_theme_font_override("font", ThemeDB.fallback_font)
	label.add_theme_color_override("font_shadow_color", Color.TRANSPARENT)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style(PANEL, 12, BORDER))
	return p


func _pad(control: Control, left: int, right: int, top: int, bottom: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", left)
	margin.add_theme_constant_override("margin_right", right)
	margin.add_theme_constant_override("margin_top", top)
	margin.add_theme_constant_override("margin_bottom", bottom)
	margin.size_flags_horizontal = control.size_flags_horizontal
	margin.size_flags_vertical = control.size_flags_vertical
	margin.add_child(control)
	return margin


func _style(color: Color, radius: int, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.set_border_width_all(1)
	s.border_color = border
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	return s


func _badge(text: String, color: Color) -> Control:
	var label := _label(text, 9, color, true)
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", _style(Color(color, 0.11), 5, Color(color, 0.32)))
	wrap.add_child(_pad(label, 5, 5, 2, 2))
	return wrap


func _toast(text: String) -> void:
	if status_label != null:
		status_label.text = text


func _format_time(value: float) -> String:
	var mins := int(value) / 60
	var secs := int(value) % 60
	var millis := int((value - floor(value)) * 1000)
	return "%02d:%02d.%03d" % [mins, secs, millis]
