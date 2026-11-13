extends Control

const SAMPLE := "res://samples/demo_track.wav"
const GRID_SCRIPT := preload("res://editor/beat_grid_canvas.gd")
const BPM_SCRIPT := preload("res://editor/bpm_graph.gd")
const SELECT_SCRIPT := preload("res://editor/wave_select.gd")
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
var last_placed_position := Vector2(0.5, 0.5)
var brush_notes_placed := 0
var last_brush_position := Vector2(-1, -1)
var preview_grid: BeatGridCanvas
var current_tool := "Pencil"
var snap_enabled := true
var active_tab := "Notes"
var duration := 0.0
var bpm := 128.0
var song_time := 0.0
var playback_speed := 1.0
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
var tab_body: VBoxContainer
var notes_tab: Control
var metadata_tab: Control
var preview_tab: Control
var export_tab: Control
var properties_panel: VBoxContainer
var layer_list: VBoxContainer
var tree_list: VBoxContainer
var library_list: VBoxContainer
var tree_mode := "Tree"
var grid_x_slider: HSlider
var grid_y_slider: HSlider
var speed_slider: HSlider
var zoom_slider: HSlider
var meta_fields: Dictionary = {}
var file_dialog: FileDialog
var cover_dialog: FileDialog
var cover_preview: TextureRect
var audio_file_label: Label
var options_pages: Dictionary = {}
var active_options_page := "Snapping"
var notification_popup: AcceptDialog
var timeline_progress: ProgressBar
var search_input: LineEdit
var notes_count_label: Label
var selection_rect := Rect2()
var selecting := false


func _ready() -> void:
	_build_theme()
	player = AudioStreamPlayer.new()
	player.name = "MusicPlayer"
	add_child(player)
	loader = WaveformLoader.new()
	_build_shell()
	_record_history()
	_load_audio(SAMPLE)
	set_process(true)


func _process(_delta: float) -> void:
	if player != null and player.playing:
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
	if grid != null:
		grid.cursor_position = (
			_cursor_for_time(song_time) if playing and autoplay_cursor else Vector2(-1, -1)
		)
		grid.refresh()
	if preview_grid != null:
		preview_grid.cursor_position = grid.cursor_position
		preview_grid.refresh()


func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	var modifier := key.ctrl_pressed or key.meta_pressed
	var focused := get_viewport().gui_get_focus_owner()
	var text_editing := focused is LineEdit or focused is TextEdit or focused is SpinBox
	if modifier and key.keycode == KEY_Z and not text_editing:
		if key.shift_pressed:
			_redo()
		else:
			_undo()
		get_viewport().set_input_as_handled()
	elif modifier and key.keycode == KEY_Y and not text_editing:
		_redo()
		get_viewport().set_input_as_handled()
	elif modifier and key.keycode == KEY_A and not text_editing:
		_select_all_in_layer()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_DELETE and not text_editing:
		_delete_selected()
		get_viewport().set_input_as_handled()


func _record_history() -> void:
	if restoring_history:
		return
	while history.size() > history_index + 1:
		history.remove_at(history.size() - 1)
	history.append(
		{
			"notes": note_list.duplicate(true),
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
	if bpm_graph != null:
		bpm_graph.points = bpm_points.duplicate()
		bpm_graph.queue_redraw()
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
	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("separation", 0)
	add_child(outer)
	outer.add_child(_build_topbar())
	outer.add_child(_build_waveform_strip())
	outer.add_child(_build_tabs())
	tab_body = VBoxContainer.new()
	tab_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab_body.add_theme_constant_override("separation", 0)
	outer.add_child(tab_body)
	outer.add_child(_build_transport())
	_build_tab_pages()
	_show_tab("Notes")
	_build_file_dialog()
	_build_cover_dialog()
	_build_notification()


func _build_topbar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = 58
	bar.add_theme_constant_override("separation", 12)
	bar.add_child(_label("◈", 22, ACCENT))
	bar.add_child(_label("SQUIRCLE WORKSHOP", 17, TEXT, true))
	var project_name := _line_edit("Untitled beatmap")
	project_name.custom_minimum_size.x = 225
	bar.add_child(project_name)
	bar.add_child(_badge("UNSAVED", Color("#e5b75c")))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	status_label = _label("Ready · Rhythia beatmap editor", 12, MUTED)
	bar.add_child(status_label)
	var save_button := _button("Save", PANEL_ALT)
	save_button.pressed.connect(func(): _toast("Project saved locally"))
	bar.add_child(save_button)
	return _pad(bar, 18, 18, 8, 8)


func _build_waveform_strip() -> Control:
	var wrap := _panel()
	wrap.custom_minimum_size.y = 165
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	wrap.add_child(column)
	var head := HBoxContainer.new()
	head.add_child(_label("TRACK OVERVIEW", 10, MUTED, true))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var open := _button("＋ Import audio", PANEL_ALT)
	open.pressed.connect(func(): file_dialog.popup_centered_ratio(0.72))
	head.add_child(open)
	var fit := _button("Fit", PANEL_ALT)
	fit.pressed.connect(func(): waveform.reset_view())
	head.add_child(fit)
	column.add_child(head)
	waveform = WaveformView.new()
	waveform.custom_minimum_size = Vector2(300, 82)
	waveform.size_flags_vertical = Control.SIZE_EXPAND_FILL
	waveform.background = Color("#11151d")
	waveform.background_bottom = Color("#141a24")
	waveform.wave_color_top = Color("#8baeff")
	waveform.wave_color_bottom = Color("#3b5f9c")
	waveform.rms_color = Color("#bfd4ff", 0.7)
	waveform.smoothing = 1
	waveform.follow_playhead = false
	waveform.follow_style = "center"
	waveform.seek_requested.connect(_seek_ratio)
	column.add_child(waveform)
	wave_overlay = SELECT_SCRIPT.new()
	wave_overlay.waveform = waveform
	wave_overlay.region_selected.connect(_on_wave_region_selected)
	wave_overlay.note_selected.connect(_select_note_by_id)
	wave_overlay.note_delete_requested.connect(_delete_note_by_id)
	waveform.add_child(wave_overlay)
	bpm_graph = BPM_SCRIPT.new()
	bpm_graph.waveform = waveform
	waveform.view_changed.connect(func(_start, _zoom): bpm_graph.queue_redraw())
	bpm_graph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bpm_graph.points = bpm_points
	bpm_graph.visible = false
	bpm_graph.points_changed.connect(_on_bpm_points_changed)
	waveform.add_child(bpm_graph)
	var minirow := HBoxContainer.new()
	minirow.add_child(_label("MINIMAP", 9, MUTED, true))
	minimap = WaveformView.new()
	minimap.custom_minimum_size = Vector2(120, 24)
	minimap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	minimap.background = Color("#0d1117")
	minimap.background_bottom = Color("#0d1117")
	minimap.wave_color_top = Color("#8aa0c4")
	minimap.wave_color_bottom = Color("#42516a")
	minimap.smoothing = 2
	minimap.follow_playhead = false
	mini_overlay = SELECT_SCRIPT.new()
	mini_overlay.waveform = minimap
	mini_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap.add_child(mini_overlay)
	minimap.seek_requested.connect(
		func(ratio):
			_seek_ratio(ratio)
			waveform.view_start = clampf(ratio - 0.15, 0.0, 0.8)
	)
	minirow.add_child(minimap)
	var speed := _label("Speed", 10, MUTED)
	minirow.add_child(speed)
	speed_slider = HSlider.new()
	speed_slider.min_value = 0.5
	speed_slider.max_value = 1.5
	speed_slider.step = 0.05
	speed_slider.value = 1.0
	speed_slider.custom_minimum_size.x = 92
	speed_slider.value_changed.connect(_on_speed_changed)
	minirow.add_child(speed_slider)
	column.add_child(minirow)
	var marker_row := HBoxContainer.new()
	marker_row.add_child(_label("MARKERS", 9, MUTED, true))
	for m in markers:
		marker_row.add_child(_badge(str(m.get("name", "Marker")), Color("#e6c45e")))
	column.add_child(marker_row)
	return _pad(wrap, 12, 12, 8, 8)


func _build_tabs() -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 46
	row.add_theme_constant_override("separation", 4)
	for tab in ["Metadata", "Notes", "Preview", "Export"]:
		var button := _button(tab, PANEL)
		button.custom_minimum_size = Vector2(140, 36)
		button.pressed.connect(_show_tab.bind(tab))
		row.add_child(button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_label("3×3 · Hover-to-hit", 11, CYAN))
	return _pad(row, 18, 18, 3, 5)


func _build_transport() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = 62
	bar.add_theme_constant_override("separation", 12)
	play_button = _button("▶", ACCENT)
	play_button.custom_minimum_size = Vector2(48, 38)
	play_button.pressed.connect(_toggle_play)
	bar.add_child(play_button)
	var stop := _button("■", PANEL_ALT)
	stop.pressed.connect(
		func():
			player.stop()
			playing = false
			_set_play_button()
	)
	bar.add_child(stop)
	time_label = _label("00:00.000  /  00:00.000", 12, Color("#f4d675"), true)
	bar.add_child(time_label)
	scrub_slider = HSlider.new()
	var scrub := scrub_slider
	scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrub.min_value = 0
	scrub.max_value = 100
	scrub.value = 0
	scrub.value_changed.connect(_on_scrub_changed)
	bar.add_child(scrub)
	timeline_progress = ProgressBar.new()
	timeline_progress.visible = false
	var notes := _label("0 notes", 11, MUTED)
	bar.add_child(notes)
	notes_count_label = notes
	bar.add_child(_badge("AUTO-ADVANCE OFF", Color("#9199a8")))
	return _pad(bar, 18, 18, 8, 8)


func _build_tab_pages() -> void:
	metadata_tab = _build_metadata_page()
	notes_tab = _build_notes_page()
	preview_tab = _build_preview_page()
	export_tab = _build_export_page()
	for page in [metadata_tab, notes_tab, preview_tab, export_tab]:
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		tab_body.add_child(page)


func _show_tab(tab: String) -> void:
	active_tab = tab
	var pages := {
		"Metadata": metadata_tab, "Notes": notes_tab, "Preview": preview_tab, "Export": export_tab
	}
	for child in tab_body.get_children():
		child.visible = child == pages.get(tab)
	_toast("%s workspace" % tab)


func _build_metadata_page() -> Control:
	var page := _panel()
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)
	var root := HBoxContainer.new()
	root.custom_minimum_size.y = 760
	root.add_theme_constant_override("separation", 24)
	scroll.add_child(root)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 650
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(left)
	left.add_child(_section_title("Beatmap metadata", "IDENTITY & TIMING"))
	var coverrow := HBoxContainer.new()
	coverrow.add_child(_cover_card())
	var coverbuttons := VBoxContainer.new()
	var choose_cover := _button("Choose cover image", PANEL_ALT)
	choose_cover.pressed.connect(func(): cover_dialog.popup_centered_ratio(0.72))
	coverbuttons.add_child(choose_cover)
	var remove_cover := _button("Remove cover", PANEL_ALT)
	remove_cover.pressed.connect(_remove_cover)
	coverbuttons.add_child(remove_cover)
	coverrow.add_child(coverbuttons)
	left.add_child(coverrow)
	for field in [
		"Artist", "Romanised artist", "Title", "Romanised title", "Source", "Mapper", "Description"
	]:
		var input := _line_edit("Enter " + field.to_lower())
		if field == "Title":
			input.text = "Untitled Rhythia map"
		if field == "Description":
			input.custom_minimum_size.y = 70
		left.add_child(_field(field, input))
		meta_fields[field] = input
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 310
	root.add_child(right)
	right.add_child(_section_title("Map settings", "DIFFICULTY & AUDIO"))
	var difficulty := OptionButton.new()
	difficulty.add_item("Easy")
	difficulty.add_item("Medium")
	difficulty.add_item("Logic")
	difficulty.add_item("Tasukete")
	difficulty.select(1)
	right.add_child(_field("Difficulty", difficulty))
	var bpm_spin := SpinBox.new()
	bpm_spin.min_value = 20
	bpm_spin.max_value = 500
	bpm_spin.step = 0.01
	bpm_spin.value = bpm
	bpm_spin.value_changed.connect(_on_initial_bpm_changed)
	right.add_child(_field("Initial BPM", bpm_spin))
	var audio_card := _panel()
	audio_card.custom_minimum_size.y = 90
	var audio_col := VBoxContainer.new()
	audio_col.add_child(_label("AUDIO FILE", 10, MUTED, true))
	audio_file_label = _label("No audio selected", 13, TEXT)
	audio_col.add_child(audio_file_label)
	var browse := _button("Import MP3 / OGG / WAV", PANEL_ALT)
	browse.pressed.connect(func(): file_dialog.popup_centered_ratio(0.72))
	audio_col.add_child(browse)
	audio_card.add_child(audio_col)
	right.add_child(audio_card)
	right.add_child(_label("Audio formats: MP3, OGG, WAV", 11, MUTED))
	return _pad(page, 24, 24, 20, 20)


func _show_options_page(page_name: String) -> void:
	active_options_page = page_name
	for key in options_pages:
		options_pages[key].visible = key == page_name


func _build_notes_page() -> Control:
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	var left := _panel()
	left.custom_minimum_size.x = 224
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var leftcol := VBoxContainer.new()
	left.add_child(leftcol)
	var lefthead := HBoxContainer.new()
	lefthead.add_child(_label("OBJECTS", 11, MUTED, true))
	var leftspace := Control.new()
	leftspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lefthead.add_child(leftspace)
	var add_marker := _button("＋ Marker", PANEL_ALT)
	add_marker.pressed.connect(func(): _add_marker_at_time(song_time))
	lefthead.add_child(add_marker)
	leftcol.add_child(lefthead)
	var browser_tabs := HBoxContainer.new()
	for kind in ["Tree", "Library"]:
		var button := _button(kind, PANEL_ALT)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_set_tree_mode.bind(kind))
		browser_tabs.add_child(button)
	leftcol.add_child(browser_tabs)
	search_input = _line_edit("Search markers…")
	search_input.text_changed.connect(func(_text): _refresh_object_list())
	leftcol.add_child(search_input)
	tree_list = VBoxContainer.new()
	tree_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	leftcol.add_child(tree_list)
	library_list = VBoxContainer.new()
	library_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	leftcol.add_child(library_list)
	page.add_child(_pad(left, 8, 8, 8, 8))

	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_theme_constant_override("separation", 8)
	page.add_child(center)
	var toolrow := HBoxContainer.new()
	toolrow.add_child(_label("TOOLS", 10, MUTED, true))
	for tool in ["Select", "Pencil", "Brush", "Line", "Path", "Curve", "Marker"]:
		var button := _button(tool, PANEL_ALT)
		button.pressed.connect(_set_tool.bind(tool))
		toolrow.add_child(button)
	var tool_spacer := Control.new()
	tool_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolrow.add_child(tool_spacer)
	var bpm_button := _button("⌁ BPM graph", PANEL_ALT)
	bpm_button.pressed.connect(_toggle_bpm_graph)
	toolrow.add_child(bpm_button)
	var bpm_input := SpinBox.new()
	bpm_input.min_value = 20
	bpm_input.max_value = 500
	bpm_input.step = 0.01
	bpm_input.value = bpm
	bpm_input.custom_minimum_size.x = 105
	bpm_input.prefix = "BPM "
	bpm_input.value_changed.connect(_on_initial_bpm_changed)
	toolrow.add_child(bpm_input)
	center.add_child(toolrow)

	var workarea := HBoxContainer.new()
	workarea.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workarea.add_theme_constant_override("separation", 10)
	center.add_child(workarea)
	var gridwrap := _panel()
	gridwrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gridwrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var gridbox := VBoxContainer.new()
	gridbox.alignment = BoxContainer.ALIGNMENT_CENTER
	gridbox.add_theme_constant_override("separation", 8)
	gridwrap.add_child(gridbox)
	var gridtitle := HBoxContainer.new()
	gridtitle.add_child(_label("PLAYFIELD · HOVER-TO-HIT", 10, MUTED, true))
	var grid_spacer := Control.new()
	grid_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gridtitle.add_child(grid_spacer)
	gridtitle.add_child(_badge("3×3 DEFAULT", CYAN))
	gridbox.add_child(gridtitle)
	grid = GRID_SCRIPT.new()
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	grid.custom_minimum_size = Vector2(320, 320)
	grid.grid_clicked.connect(_on_grid_clicked)
	grid.grid_dragged.connect(_on_grid_dragged)
	grid.grid_hovered.connect(_on_grid_hovered)
	grid.note_delete_requested.connect(_delete_note_by_id)
	gridbox.add_child(grid)
	gridbox.add_child(
		_label("Pencil places notes here · Shift temporarily disables snapping", 10, MUTED)
	)
	workarea.add_child(gridwrap)

	var options := _panel()
	options.custom_minimum_size.x = 250
	options.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var options_col := VBoxContainer.new()
	options.add_child(options_col)
	options_col.add_child(_label("EDITOR OPTIONS", 10, MUTED, true))
	var option_tabs := HBoxContainer.new()
	for tab_name in ["Snapping", "Graphics", "Edit"]:
		var tab_button := _button(tab_name, PANEL_ALT)
		tab_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab_button.pressed.connect(_show_options_page.bind(tab_name))
		option_tabs.add_child(tab_button)
	options_col.add_child(option_tabs)
	var options_scroll := ScrollContainer.new()
	options_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	options_col.add_child(options_scroll)
	var options_stack := VBoxContainer.new()
	options_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	options_scroll.add_child(options_stack)
	options_pages.clear()

	var snapping_page := VBoxContainer.new()
	snapping_page.add_theme_constant_override("separation", 8)
	snapping_page.add_child(_section_title("Snapping", "PLACEMENT"))
	var auto_advance_toggle := CheckBox.new()
	auto_advance_toggle.text = "Auto-advance"
	auto_advance_toggle.toggled.connect(func(enabled): auto_advance = enabled)
	snapping_page.add_child(auto_advance_toggle)
	var snapping_toggle := CheckBox.new()
	snapping_toggle.text = "Enable snapping (Shift bypasses)"
	snapping_toggle.button_pressed = true
	snapping_toggle.toggled.connect(
		func(enabled):
			snap_enabled = enabled
			grid.snap_enabled = enabled
			grid.refresh()
	)
	snapping_page.add_child(snapping_toggle)
	snapping_page.add_child(_label("Grid divisor · X", 11, TEXT))
	grid_x_slider = HSlider.new()
	grid_x_slider.min_value = 1
	grid_x_slider.max_value = 32
	grid_x_slider.step = 1
	grid_x_slider.value = 3
	grid_x_slider.value_changed.connect(_on_grid_x_changed)
	snapping_page.add_child(grid_x_slider)
	snapping_page.add_child(_label("Grid divisor · Y", 11, TEXT))
	grid_y_slider = HSlider.new()
	grid_y_slider.min_value = 1
	grid_y_slider.max_value = 32
	grid_y_slider.step = 1
	grid_y_slider.value = 3
	grid_y_slider.value_changed.connect(_on_grid_y_changed)
	snapping_page.add_child(grid_y_slider)
	var link_snap := CheckBox.new()
	link_snap.text = "Link X and Y"
	link_snap.button_pressed = true
	link_snap.add_to_group("grid_snap_link")
	link_snap.toggled.connect(_on_snap_link_toggled)
	snapping_page.add_child(link_snap)
	snapping_page.add_child(_label("Grid offset · X", 11, TEXT))
	var offset_x := HSlider.new()
	offset_x.min_value = -0.5
	offset_x.max_value = 0.5
	offset_x.step = 0.01
	offset_x.value_changed.connect(
		func(value):
			grid.grid_offset.x = value
			grid.refresh()
	)
	snapping_page.add_child(offset_x)
	snapping_page.add_child(_label("Grid offset · Y", 11, TEXT))
	var offset_y := HSlider.new()
	offset_y.min_value = -0.5
	offset_y.max_value = 0.5
	offset_y.step = 0.01
	offset_y.value_changed.connect(
		func(value):
			grid.grid_offset.y = value
			grid.refresh()
	)
	snapping_page.add_child(offset_y)
	snapping_page.add_child(_label("Beat divisor", 11, TEXT))
	var beat_divisor := OptionButton.new()
	for item in ["1/1", "1/2", "1/4", "1/8", "1/16", "1/32"]:
		beat_divisor.add_item(item)
	beat_divisor.select(3)
	snapping_page.add_child(beat_divisor)
	options_stack.add_child(snapping_page)
	options_pages["Snapping"] = snapping_page

	var graphics_page := VBoxContainer.new()
	graphics_page.add_theme_constant_override("separation", 10)
	graphics_page.add_child(_section_title("Graphics", "PLAYBACK"))
	var autoplay_toggle := CheckBox.new()
	autoplay_toggle.text = "Auto-play cursor"
	autoplay_toggle.button_pressed = true
	autoplay_toggle.toggled.connect(func(enabled): autoplay_cursor = enabled)
	graphics_page.add_child(autoplay_toggle)
	graphics_page.add_child(_label("Cursor smoothness", 11, TEXT))
	var smoothness := HSlider.new()
	smoothness.min_value = 0.0
	smoothness.max_value = 1.0
	smoothness.value = 0.45
	graphics_page.add_child(smoothness)
	graphics_page.add_child(_label("Approach rate", 11, TEXT))
	var approach_rate := HSlider.new()
	approach_rate.min_value = 0.2
	approach_rate.max_value = 3.0
	approach_rate.value = 1.0
	graphics_page.add_child(approach_rate)
	options_stack.add_child(graphics_page)
	options_pages["Graphics"] = graphics_page

	var edit_page := VBoxContainer.new()
	edit_page.add_theme_constant_override("separation", 10)
	edit_page.add_child(_section_title("Edit selected", "TRANSFORM"))
	var rotation := SpinBox.new()
	rotation.min_value = -360
	rotation.max_value = 360
	rotation.value = 15
	rotation.prefix = "Rotate ° "
	edit_page.add_child(rotation)
	var rotate_button := _button("Apply rotation", PANEL_ALT)
	rotate_button.pressed.connect(func(): _transform_selected(rotation.value, 1.0, false))
	edit_page.add_child(rotate_button)
	var scale_edit := SpinBox.new()
	scale_edit.min_value = 0.1
	scale_edit.max_value = 4.0
	scale_edit.step = 0.1
	scale_edit.value = 1.1
	scale_edit.prefix = "Scale × "
	edit_page.add_child(scale_edit)
	var scale_button := _button("Apply scale", PANEL_ALT)
	scale_button.pressed.connect(func(): _transform_selected(0.0, scale_edit.value, false))
	edit_page.add_child(scale_button)
	var reverse_button := _button("Reverse selected notes", PANEL_ALT)
	reverse_button.pressed.connect(func(): _transform_selected(0.0, 1.0, true))
	edit_page.add_child(reverse_button)
	options_stack.add_child(edit_page)
	options_pages["Edit"] = edit_page
	_show_options_page("Snapping")
	workarea.add_child(_pad(options, 10, 10, 10, 10))

	var bottom := HBoxContainer.new()
	bottom.custom_minimum_size.y = 140
	bottom.add_theme_constant_override("separation", 10)
	center.add_child(bottom)
	var props := _panel()
	props.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var propcol := VBoxContainer.new()
	props.add_child(propcol)
	propcol.add_child(_section_title("Selection properties", "INSPECTOR"))
	properties_panel = propcol
	bottom.add_child(_pad(props, 12, 12, 10, 10))
	var layerpanel := _panel()
	layerpanel.custom_minimum_size.x = 340
	var layercol := VBoxContainer.new()
	layerpanel.add_child(layercol)
	var layerhead := HBoxContainer.new()
	layerhead.add_child(_label("LAYERS", 10, MUTED, true))
	var layer_spacer := Control.new()
	layer_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layerhead.add_child(layer_spacer)
	var add_layer_button := _button("＋", PANEL_ALT)
	add_layer_button.pressed.connect(_add_layer)
	layerhead.add_child(add_layer_button)
	var delete_layer_button := _button("−", PANEL_ALT)
	delete_layer_button.pressed.connect(_delete_layer)
	layerhead.add_child(delete_layer_button)
	var merge_layer_button := _button("⇩", PANEL_ALT)
	merge_layer_button.tooltip_text = "Merge into layer below"
	merge_layer_button.pressed.connect(_merge_layer)
	layerhead.add_child(merge_layer_button)
	layercol.add_child(layerhead)
	layer_list = VBoxContainer.new()
	layercol.add_child(layer_list)
	bottom.add_child(_pad(layerpanel, 10, 10, 8, 8))
	_refresh_object_list()
	_refresh_layers()
	_show_properties()
	return _pad(page, 8, 8, 8, 8)


func _build_preview_page() -> Control:
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 20)
	var main := _panel()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 18)
	main.add_child(col)
	col.add_child(_label("GAME PREVIEW", 11, MUTED, true))
	var playfield := GRID_SCRIPT.new()
	preview_grid = playfield
	playfield.is_3d_preview = true
	playfield.custom_minimum_size = Vector2(460, 460)
	playfield.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	playfield.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	playfield.notes = note_list
	playfield.grid_clicked.connect(func(pos): _on_grid_clicked(pos))
	playfield.grid_dragged.connect(_on_grid_dragged)
	playfield.grid_hovered.connect(_on_grid_hovered)
	playfield.note_delete_requested.connect(_delete_note_by_id)
	col.add_child(playfield)
	col.add_child(
		_label(
			"Autoplay cursor continues until you take control · ESC returns to autoplay", 11, MUTED
		)
	)
	page.add_child(_pad(main, 20, 20, 16, 16))
	var side := _panel()
	side.custom_minimum_size.x = 250
	var sidecol := VBoxContainer.new()
	side.add_child(sidecol)
	sidecol.add_child(_section_title("Playtest", "RHYTHIA SIMULATION"))
	sidecol.add_child(_label("Hover-to-hit model", 12, CYAN, true))
	var playtest_hint := _label(
		"Move the cursor over each note as it reaches the 3×3 field. No clicking is required in game.",
		12,
		MUTED
	)
	sidecol.add_child(playtest_hint)
	var check := CheckBox.new()
	check.text = "Auto-play cursor"
	check.button_pressed = true
	check.toggled.connect(func(v): autoplay_cursor = v)
	sidecol.add_child(check)
	var speed := HSlider.new()
	speed.min_value = 0.5
	speed.max_value = 1.5
	speed.value = 1.0
	speed.value_changed.connect(
		func(v):
			playback_speed = v
			player.pitch_scale = v
	)
	sidecol.add_child(speed)
	sidecol.add_child(_button("Restart preview", PANEL_ALT))
	page.add_child(_pad(side, 16, 16, 14, 14))
	return _pad(page, 10, 10, 10, 10)


func _build_export_page() -> Control:
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 18)
	var main := _panel()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var col := VBoxContainer.new()
	main.add_child(col)
	col.add_child(_section_title("Export beatmap", "WIP · RHYTHIA"))
	col.add_child(
		_label("Choose a format and review the baked note output before exporting.", 12, MUTED)
	)
	var format := OptionButton.new()
	format.add_item("Rhythia Map (.rhm)")
	format.add_item("JSON (debug)")
	col.add_child(_field("Format", format))
	var settings := CheckBox.new()
	settings.text = "Bake paths, curves and brush strokes into simple notes"
	settings.button_pressed = true
	col.add_child(settings)
	var notes_toggle := CheckBox.new()
	notes_toggle.text = "Include metadata and layer colors"
	notes_toggle.button_pressed = true
	col.add_child(notes_toggle)
	var export_button := _button("Export beatmap", ACCENT)
	export_button.pressed.connect(_show_export_notice)
	col.add_child(export_button)
	page.add_child(_pad(main, 24, 24, 20, 20))
	var issues := _panel()
	issues.custom_minimum_size.x = 400
	var issuecol := VBoxContainer.new()
	issues.add_child(issuecol)
	issuecol.add_child(_section_title("Verifier", "NOTIFICATIONS"))
	issuecol.add_child(_badge("2 warnings · 1 info", Color("#e6bc66")))
	issuecol.add_child(_issue("WARNING", "No creator / mapper name has been set."))
	issuecol.add_child(_issue("WARNING", "Audio file must be included with the exported beatmap."))
	issuecol.add_child(
		_issue("INFO", "Complex drawing tools will be baked to standard Rhythia notes.")
	)
	var verify_button := _button("Run verifier", PANEL_ALT)
	verify_button.pressed.connect(_show_export_notice)
	issuecol.add_child(verify_button)
	page.add_child(_pad(issues, 16, 16, 14, 14))
	return _pad(page, 10, 10, 10, 10)


func _show_export_notice() -> void:
	notification_popup.dialog_text = "2 warnings found\n\n• Add creator / mapper metadata before publishing.\n• Include the audio file alongside the exported beatmap.\n\nComplex tools are baked into standard Rhythia notes. Export format support is a work in progress."
	notification_popup.popup_centered(Vector2i(520, 280))


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


func _build_cover_dialog() -> void:
	cover_dialog = FileDialog.new()
	cover_dialog.access = FileDialog.ACCESS_FILESYSTEM
	cover_dialog.use_native_dialog = true
	cover_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	cover_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Cover images"])
	cover_dialog.file_selected.connect(_load_cover)
	add_child(cover_dialog)


func _load_cover(path: String) -> void:
	var image := Image.new()
	if image.load(path) == OK:
		cover_preview.texture = ImageTexture.create_from_image(image)


func _remove_cover() -> void:
	if cover_preview != null:
		cover_preview.texture = null


func _build_notification() -> void:
	notification_popup = AcceptDialog.new()
	notification_popup.title = "Beatmap check"
	notification_popup.dialog_text = "Warnings and export information will appear here."
	add_child(notification_popup)


func _load_audio(path: String) -> void:
	if path.is_empty():
		return
	file_path = path
	status_label.text = "Loading waveform…"
	var pyramid: WaveformPyramid = await loader.load_pyramid(path)
	if pyramid == null:
		status_label.text = "Could not load audio: " + loader.last_error
		return
	waveform.pyramid = pyramid
	minimap.pyramid = pyramid
	var stream := WaveformBaker.load_audio_stream(path)
	if stream != null:
		player.stream = stream
		duration = stream.get_length()
		player.pitch_scale = playback_speed
	else:
		duration = pyramid.duration
	status_label.text = "%s · %.2fs · waveform %s" % [path.get_file(), duration, loader.last_source]
	if audio_file_label != null:
		audio_file_label.text = path.get_file()
	if (
		meta_fields.has("Title")
		and (meta_fields["Title"] as LineEdit).text == "Untitled Rhythia map"
	):
		(meta_fields["Title"] as LineEdit).text = path.get_file().get_basename()


func _on_speed_changed(value: float) -> void:
	playback_speed = value
	if player.stream != null:
		player.pitch_scale = value


func _on_scrub_changed(value: float) -> void:
	if duration > 0.0 and not player.playing:
		_seek_ratio(value / 100.0)


func _on_initial_bpm_changed(value: float) -> void:
	bpm = value
	bpm_points[0] = Vector2(bpm_points[0].x, value)
	if bpm_graph != null and bpm_graph.points.size() > 0:
		bpm_graph.points[0] = Vector2(bpm_graph.points[0].x, value)
		bpm_graph.queue_redraw()
	if bpm_label != null:
		bpm_label.text = "BPM  %.2f" % bpm
	_record_history()


func _on_snap_link_toggled(enabled: bool) -> void:
	if enabled:
		grid_y_slider.value = grid_x_slider.value


func _on_grid_x_changed(value: float) -> void:
	grid.snap_x = int(value)
	for node in get_tree().get_nodes_in_group("grid_snap_link"):
		var checkbox := node as CheckBox
		if checkbox != null and checkbox.button_pressed:
			grid_y_slider.value = value


func _on_grid_y_changed(value: float) -> void:
	grid.snap_y = int(value)
	for node in get_tree().get_nodes_in_group("grid_snap_link"):
		var checkbox := node as CheckBox
		if checkbox != null and checkbox.button_pressed:
			grid_x_slider.value = value


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


func _seek_ratio(ratio: float) -> void:
	if duration <= 0.0:
		return
	song_time = clampf(ratio, 0.0, 1.0) * duration
	waveform.playback_ratio = clampf(song_time / maxf(duration, 0.01), 0.0, 1.0)
	minimap.playback_ratio = waveform.playback_ratio
	if time_label != null:
		time_label.text = "%s  /  %s" % [_format_time(song_time), _format_time(duration)]
	if player.stream != null:
		var resume := playing
		player.play(song_time)
		if not resume:
			player.stream_paused = true
	playing = player.playing and not player.stream_paused
	_set_play_button()


func _on_grid_clicked(position: Vector2) -> void:
	if current_tool == "Select":
		var nearest := ""
		var best := 0.07
		for n in note_list:
			var d := position.distance_to(Vector2(n.x, n.y))
			if d < best:
				best = d
				nearest = str(n.id)
		if nearest != "":
			selected_id = nearest
			selected_ids = [nearest]
			_show_properties()
			grid.selected_id = selected_id
			grid.selected_ids = selected_ids
			grid.refresh()
		return
	if current_tool == "Marker":
		_add_marker_at_time(song_time)
		_toast("Marker added at %s" % _format_time(song_time))
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
	elif current_tool in ["Line", "Path", "Curve"] and not note_list.is_empty():
		var start := last_placed_position
		for i in range(1, 9):
			var t := float(i) / 8.0
			var point := start.lerp(Vector2(x, y), t)
			if current_tool == "Path":
				point.y += sin(t * PI * 2.0) * 0.12
			elif current_tool == "Curve":
				point.y += sin(t * PI) * 0.2
			_append_note(point, song_time + t * _bar_seconds(), current_tool, false)
		_record_history()
	else:
		_append_note(Vector2(x, y), song_time, current_tool)
	last_placed_position = Vector2(x, y)
	if auto_advance:
		song_time += _bar_seconds()
		if player.stream != null:
			_seek_ratio(song_time / maxf(duration, 0.01))
	_refresh_object_list()
	_show_properties()
	_sync_grid()


func _add_marker_at_time(at_time: float) -> void:
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
	var new_note := {
		"id": str(Time.get_ticks_usec() + note_list.size()),
		"x": clampf(position.x, 0.02, 0.98),
		"y": clampf(position.y, 0.02, 0.98),
		"time": at_time,
		"bar": _time_to_bar(at_time),
		"layer": str(layers[current_layer].name),
		"type": note_type
	}
	note_list.append(new_note)
	selected_id = str(new_note.id)
	selected_ids = [selected_id]
	if record:
		_record_history()


func _set_tool(tool: String) -> void:
	current_tool = tool
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
	if not bpm_points.is_empty():
		bpm = bpm_points[0].y
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
	if tree_list == null:
		return
	for child in tree_list.get_children():
		child.queue_free()
	for child in library_list.get_children():
		child.queue_free()
	tree_list.visible = tree_mode == "Tree"
	library_list.visible = tree_mode == "Library"
	if tree_mode == "Library":
		for pattern in ["Basic 3-note burst", "Zig-zag", "Diagonal run", "Center alternation"]:
			var b := _button("▦  " + pattern, PANEL_ALT)
			b.pressed.connect(func(): _place_pattern())
			library_list.add_child(b)
		library_list.add_child(_button("＋ Save selection as pattern", PANEL_ALT))
		return
	var query := search_input.text.to_lower() if search_input != null else ""
	for item in markers:
		_add_tree_item(
			"◆",
			str(item.name),
			float(item.time),
			Color("#e6c45e"),
			query,
			func():
				selected_id = str(item.get("id", ""))
				selected_ids.clear()
				_seek_ratio(float(item.time) / maxf(duration, 0.01))
				_show_properties()
		)
	if tree_list.get_child_count() == 0:
		tree_list.add_child(_label("No markers yet. Add a marker at the playhead.", 11, MUTED))


func _add_tree_item(
	icon: String, name: String, time: float, color: Color, query: String, action: Callable
) -> void:
	if query != "" and not name.to_lower().contains(query):
		return
	var row := HBoxContainer.new()
	var b := _button(icon + "  " + name, PANEL_ALT)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(action)
	row.add_child(b)
	var pin := _button("⌖", PANEL_ALT)
	row.add_child(pin)
	tree_list.add_child(row)
	tree_list.add_child(_label("     %s" % _format_time(time), 9, MUTED))


func _show_properties() -> void:
	if properties_panel == null:
		return
	for child in properties_panel.get_children():
		child.queue_free()
	properties_panel.add_child(_section_title("Selected object", "PROPERTIES"))
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
	var row := HBoxContainer.new()
	row.add_child(_label("● Note", 12, ACCENT, true))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var duplicate_button := _button("Duplicate", PANEL_ALT)
	duplicate_button.pressed.connect(_duplicate_selected)
	row.add_child(duplicate_button)
	var delete_button := _button("Delete", PANEL_ALT)
	delete_button.pressed.connect(_delete_selected)
	row.add_child(delete_button)
	properties_panel.add_child(row)
	var fields := HBoxContainer.new()
	fields.add_child(
		_property_spin(
			"Time (s)",
			float(selected.time),
			0,
			maxf(duration, 999),
			0.001,
			func(v):
				selected.time = v
				selected.bar = _time_to_bar(v)
				_record_history()
				_refresh_object_list()
		)
	)
	fields.add_child(
		_property_spin(
			"X",
			float(selected.x),
			0,
			1,
			0.01,
			func(v):
				selected.x = v
				_record_history()
				_sync_grid()
		)
	)
	fields.add_child(
		_property_spin(
			"Y",
			float(selected.y),
			0,
			1,
			0.01,
			func(v):
				selected.y = v
				_record_history()
				_sync_grid()
		)
	)
	var layeropt := OptionButton.new()
	for layer in layers:
		layeropt.add_item(str(layer.name))
	layeropt.select(current_layer)
	layeropt.item_selected.connect(
		func(i):
			selected.layer = str(layers[i].name)
			_record_history()
			_sync_grid()
	)
	fields.add_child(_field("Layer", layeropt))
	properties_panel.add_child(fields)
	properties_panel.add_child(
		_label("Bar %.3f · %s" % [float(selected.bar), selected.layer], 10, MUTED)
	)
	var transform_row := HBoxContainer.new()
	var angle := SpinBox.new()
	angle.min_value = -360
	angle.max_value = 360
	angle.value = 15
	angle.prefix = "Rotate ° "
	transform_row.add_child(angle)
	var rotate_button := _button("Apply", PANEL_ALT)
	rotate_button.pressed.connect(func(): _transform_selected(angle.value, 1.0, false))
	transform_row.add_child(rotate_button)
	var scale_input := SpinBox.new()
	scale_input.min_value = 0.1
	scale_input.max_value = 4.0
	scale_input.step = 0.1
	scale_input.value = 1.1
	scale_input.prefix = "Scale × "
	transform_row.add_child(scale_input)
	var scale_button := _button("Apply", PANEL_ALT)
	scale_button.pressed.connect(func(): _transform_selected(0.0, scale_input.value, false))
	transform_row.add_child(scale_button)
	var reverse_button := _button("Reverse", PANEL_ALT)
	reverse_button.pressed.connect(func(): _transform_selected(0.0, 1.0, true))
	transform_row.add_child(reverse_button)
	properties_panel.add_child(transform_row)


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
		name_button.pressed.connect(func(): current_layer = i)
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
		var settings := _button("⚙", PANEL_ALT)
		settings.pressed.connect(func(): _open_layer_settings(layer))
		row.add_child(settings)
		layer_list.add_child(row)


func _open_layer_settings(layer: Dictionary) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Layer settings · %s" % str(layer.name)
	dialog.dialog_text = "Choose the layer opacity. Color is changed from the swatch."
	var slider := HSlider.new()
	slider.min_value = 0.1
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(layer.opacity)
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
	grid.selected_id = selected_id
	grid.selected_ids = selected_ids
	grid.visible_layers.clear()
	grid.layer_colors.clear()
	grid.layer_opacities.clear()
	for layer in layers:
		grid.visible_layers[layer.name] = layer.visible
		grid.layer_colors[layer.name] = layer.color
		grid.layer_opacities[layer.name] = layer.opacity
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
		preview_grid.selected_id = selected_id
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


func _merge_layer() -> void:
	if current_layer <= 0:
		_toast("There is no layer below this one to merge into.")
		return
	var source_name := str(layers[current_layer].name)
	var target_name := str(layers[current_layer - 1].name)
	for note in note_list:
		if str(note.layer) == source_name:
			note.layer = target_name
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
	_record_history()
	for n in note_list:
		if str(n.layer) == removed:
			n.layer = str(layers[current_layer].name)
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


func _cover_card() -> Control:
	var card := _panel()
	card.custom_minimum_size = Vector2(110, 116)
	cover_preview = TextureRect.new()
	cover_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	cover_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cover_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(cover_preview)
	var cover_hint := _label("No cover", 10, MUTED)
	cover_hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cover_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cover_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cover_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(cover_hint)
	return card


func _issue(level: String, text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_child(_badge(level, Color("#ec7878")))
	row.add_child(_label(text, 11, TEXT))
	return row


func _button(text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
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
