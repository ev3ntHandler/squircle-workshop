extends Control

signal points_changed(points: Array)

var waveform: WaveformView
var points: Array[Vector2] = [Vector2(0, 128), Vector2(1, 128)]
var selected := -1
var dragging := false
var drag_moved := false
var pressed_existing := false
var press_position := Vector2.ZERO
var min_bpm := 40.0
var max_bpm := 300.0
var context_menu: PopupMenu
var value_dialog: ConfirmationDialog
var value_spin: SpinBox


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	context_menu = PopupMenu.new()
	context_menu.add_item("Input value…", 1)
	context_menu.id_pressed.connect(_on_context_action)
	add_child(context_menu)
	value_dialog = ConfirmationDialog.new()
	value_dialog.title = "Set BPM value"
	value_spin = SpinBox.new()
	value_spin.min_value = min_bpm
	value_spin.max_value = max_bpm
	value_spin.step = 0.01
	value_dialog.add_child(value_spin)
	value_dialog.confirmed.connect(_apply_input_value)
	value_spin.get_line_edit().text_submitted.connect(_submit_input_value)
	add_child(value_dialog)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var nearest := _nearest_point(event.position)
			pressed_existing = nearest >= 0
			drag_moved = false
			press_position = event.position
			if nearest >= 0:
				selected = nearest
			else:
				points.append(_value(event.position))
				_sort_points()
				selected = _nearest_index(_value(event.position).x)
				points_changed.emit(points)
			dragging = true
			queue_redraw()
			accept_event()
		else:
			if (
				dragging
				and pressed_existing
				and not drag_moved
				and selected >= 0
				and selected < points.size()
			):
				if points.size() > 1:
					points.remove_at(selected)
				selected = -1
				points_changed.emit(points)
			dragging = false
			pressed_existing = false
			queue_redraw()
			accept_event()
	elif (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_RIGHT
		and event.pressed
	):
		selected = _nearest_point(event.position)
		if selected >= 0:
			context_menu.position = Vector2i(get_global_mouse_position())
			context_menu.popup()
		accept_event()
	elif (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_WHEEL_UP
	):
		if waveform != null:
			waveform.zoom_at(waveform.zoom_step, event.position.x / maxf(size.x, 1.0))
		accept_event()
	elif (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_WHEEL_DOWN
	):
		if waveform != null:
			waveform.zoom_at(1.0 / waveform.zoom_step, event.position.x / maxf(size.x, 1.0))
		accept_event()
	elif event is InputEventMouseMotion and dragging and selected >= 0 and selected < points.size():
		if event.position.distance_to(press_position) > 3.0:
			drag_moved = true
		var value := _value(event.position)
		var sorted := points.duplicate()
		sorted.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
		var point_index := sorted.find(points[selected])
		if point_index > 0 and point_index < sorted.size() - 1:
			value.x = clampf(
				value.x, sorted[point_index - 1].x + 0.001, sorted[point_index + 1].x - 0.001
			)
		else:
			value.x = points[selected].x
		points[selected] = value
		queue_redraw()
		points_changed.emit(points)
		accept_event()


func _on_context_action(id: int) -> void:
	if id != 1 or selected < 0 or selected >= points.size():
		return
	value_spin.value = points[selected].y
	value_dialog.popup_centered(Vector2i(300, 120))
	var edit := value_spin.get_line_edit()
	edit.grab_focus.call_deferred()
	edit.select_all.call_deferred()


func _submit_input_value(text: String) -> void:
	if text.is_valid_float():
		value_spin.value = clampf(float(text), min_bpm, max_bpm)
	_apply_input_value()
	value_dialog.hide()


func _apply_input_value() -> void:
	if selected >= 0 and selected < points.size():
		points[selected] = Vector2(points[selected].x, snappedf(value_spin.value, 0.01))
		queue_redraw()
		points_changed.emit(points)


func _value(pos: Vector2) -> Vector2:
	var ratio := clampf(pos.x / maxf(size.x, 1.0), 0.0, 1.0)
	if waveform != null:
		ratio = waveform.view_start + ratio / maxf(waveform.zoom, 1.0)
	var bpm_value := lerpf(max_bpm, min_bpm, clampf(pos.y / maxf(size.y, 1.0), 0.0, 1.0))
	var bpm_step := 0.01 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	return Vector2(clampf(ratio, 0.0, 1.0), snappedf(bpm_value, bpm_step))


func _pixel(point: Vector2) -> Vector2:
	var span := 1.0
	var start := 0.0
	if waveform != null:
		span = 1.0 / maxf(waveform.zoom, 1.0)
		start = waveform.view_start
	return Vector2(
		(point.x - start) / span * size.x, inverse_lerp(max_bpm, min_bpm, point.y) * size.y
	)


func _nearest_point(pos: Vector2) -> int:
	var nearest := -1
	var distance := 14.0
	for i in range(points.size()):
		var current := _pixel(points[i]).distance_to(pos)
		if current < distance:
			distance = current
			nearest = i
	return nearest


func _nearest_index(x: float) -> int:
	var index := 0
	var delta := INF
	for i in range(points.size()):
		var d := absf(points[i].x - x)
		if d < delta:
			delta = d
			index = i
	return index


func _sort_points() -> void:
	points.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.025, 0.035, 0.06, 0.86), true)
	for i in range(1, 5):
		var y := size.y * i / 5.0
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.55, 0.62, 0.77, 0.18), 1.0)
	var sorted := points.duplicate()
	sorted.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
	for i in range(sorted.size() - 1):
		draw_line(_pixel(sorted[i]), _pixel(sorted[i + 1]), Color("#7ce0d2"), 3.0)
	for point in sorted:
		var pos := _pixel(point)
		if pos.x < -20.0 or pos.x > size.x + 20.0:
			continue
		draw_circle(pos, 7.0, Color("#0c121a"))
		draw_circle(pos, 5.0, Color("#7ce0d2"))
		draw_string(
			ThemeDB.fallback_font,
			pos + Vector2(10, -7),
			"%.2f" % point.y,
			HORIZONTAL_ALIGNMENT_LEFT,
			80,
			11,
			Color.WHITE
		)
	draw_string(
		ThemeDB.fallback_font,
		Vector2(12, 19),
		"BPM AUTOMATION · Click to add/delete · Right click a point for input",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		10,
		Color("#dce6f3")
	)
