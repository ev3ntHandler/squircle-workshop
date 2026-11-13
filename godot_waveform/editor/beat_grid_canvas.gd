extends Control
class_name BeatGridCanvas

signal grid_clicked(position: Vector2, ctrl_pressed: bool)
signal grid_dragged(position: Vector2)
signal grid_hovered(position: Vector2)
signal note_delete_requested(id: String)
signal line_completed(start: Vector2, finish: Vector2)

var notes: Array[Dictionary] = []
var selected_id := ""
var selected_ids: Array[String] = []
var cursor_position := Vector2(-1.0, -1.0)
var ghost_position := Vector2(-1.0, -1.0)
var is_3d_preview := false
var snap_enabled := true
var snap_x := 3
var snap_y := 3
var current_time := 0.0
var approach_rate := 1.0
var animate_notes := false
var active_tool := "Pencil"
var line_start := Vector2(-1.0, -1.0)
var line_preview_position := Vector2(-1.0, -1.0)
var line_dragging := false
var right_dragging := false
var right_drag_last := Vector2.ZERO
var deleted_during_drag: Dictionary = {}
var grid_offset := Vector2.ZERO
var active_layer_color := Color("#d779fa")
var visible_layers: Dictionary = {"Layer 1": true}
var layer_colors: Dictionary = {"Layer 1": Color("#d779fa")}
var layer_opacities: Dictionary = {"Layer 1": 0.9}


func _ready() -> void:
	custom_minimum_size = Vector2(320, 320)
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hover := _normalized_position(event.position)
		ghost_position = hover
		grid_hovered.emit(hover)
		if line_dragging:
			line_preview_position = hover
			accept_event()
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			grid_dragged.emit(hover)
		if right_dragging and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_delete_notes_along_segment(right_drag_last, event.position)
			right_drag_last = event.position
			accept_event()
		queue_redraw()
	elif event is InputEventMouseButton:
		var pos := _normalized_position(event.position)
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and active_tool == "Line":
				line_start = pos
				line_preview_position = pos
				line_dragging = true
				accept_event()
			elif not event.pressed and line_dragging:
				var finish := pos
				if line_start.distance_to(finish) > 0.015:
					line_completed.emit(line_start, finish)
				cancel_line_preview()
				accept_event()
			elif event.pressed:
				grid_clicked.emit(pos, event.ctrl_pressed)
				accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				right_dragging = true
				right_drag_last = event.position
				deleted_during_drag.clear()
				_delete_notes_at(event.position)
			else:
				right_dragging = false
				deleted_during_drag.clear()
			accept_event()


func _normalized_position(position: Vector2) -> Vector2:
	return Vector2(
		clampf(position.x / maxf(size.x, 1.0), 0.0, 1.0),
		clampf(position.y / maxf(size.y, 1.0), 0.0, 1.0)
	)


func cancel_line_preview() -> void:
	line_dragging = false
	line_start = Vector2(-1.0, -1.0)
	line_preview_position = Vector2(-1.0, -1.0)
	queue_redraw()


func _delete_notes_at(pixel_position: Vector2) -> void:
	_delete_notes_along_segment(pixel_position, pixel_position)


func _delete_notes_along_segment(from: Vector2, to: Vector2) -> void:
	for note in notes.duplicate():
		var note_id := str(note.get("id", ""))
		if deleted_during_drag.has(note_id):
			continue
		var target := _project(Vector2(float(note.get("x", 0.5)), float(note.get("y", 0.5))))
		var radius := 27.0 if is_3d_preview else 30.0
		if Geometry2D.get_closest_point_to_segment(target, from, to).distance_to(target) <= radius:
			deleted_during_drag[note_id] = true
			note_delete_requested.emit(note_id)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		ghost_position = Vector2(-1.0, -1.0)
		queue_redraw()


func _project(point: Vector2) -> Vector2:
	if not is_3d_preview:
		return point * size
	var top_left := Vector2(size.x * 0.16, size.y * 0.12)
	var top_right := Vector2(size.x * 0.84, size.y * 0.12)
	var bottom_left := Vector2(size.x * 0.04, size.y * 0.92)
	var bottom_right := Vector2(size.x * 0.96, size.y * 0.92)
	return top_left.lerp(top_right, point.x).lerp(bottom_left.lerp(bottom_right, point.x), point.y)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0b0d11"), true)
	var top_left := _project(Vector2.ZERO)
	var top_right := _project(Vector2.RIGHT)
	var bottom_left := _project(Vector2.DOWN)
	var bottom_right := _project(Vector2.ONE)
	draw_colored_polygon(
		PackedVector2Array([top_left, top_right, bottom_right, bottom_left]), Color("#11151d")
	)
	for i in range(snap_x + 1):
		var fraction := clampf(float(i) / float(snap_x) + grid_offset.x / float(snap_x), 0.0, 1.0)
		draw_line(
			_project(Vector2(fraction, 0)),
			_project(Vector2(fraction, 1)),
			Color(0.36, 0.4, 0.48, 0.55),
			1.0
		)
	for i in range(snap_y + 1):
		var fraction := clampf(float(i) / float(snap_y) + grid_offset.y / float(snap_y), 0.0, 1.0)
		draw_line(
			_project(Vector2(0, fraction)),
			_project(Vector2(1, fraction)),
			Color(0.36, 0.4, 0.48, 0.55),
			1.0
		)
	if is_3d_preview:
		draw_line(top_left, top_right, Color("#9bb5d3", 0.8), 2.0)
		draw_line(top_right, bottom_right, Color("#9bb5d3", 0.8), 2.0)
		draw_line(bottom_right, bottom_left, Color("#9bb5d3", 0.8), 2.0)
		draw_line(bottom_left, top_left, Color("#9bb5d3", 0.8), 2.0)
	else:
		for index in range(9):
			var label: String = ["Q", "W", "E", "A", "S", "D", "Z", "X", "C"][index]
			var label_pos := _project(
				Vector2((index % 3 + 0.5) / 3.0, (floori(index / 3.0) + 0.5) / 3.0)
			)
			draw_string(
				ThemeDB.fallback_font,
				label_pos + Vector2(-4, 5),
				label,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				14,
				Color(0.48, 0.51, 0.59, 0.24)
			)
	var approach_window := 2.4 / maxf(approach_rate, 0.2)
	for note in notes:
		var layer_name := str(note.get("layer", "Layer 1"))
		if not bool(visible_layers.get(layer_name, true)):
			continue
		var arrival := float(note.get("time", 0.0)) - current_time
		var opacity := 1.0
		if animate_notes:
			if arrival < 0.0 or arrival > approach_window:
				continue
			opacity = clampf(1.0 - arrival / approach_window, 0.02, 1.0)
		var target := Vector2(float(note.get("x", 0.5)), float(note.get("y", 0.5)))
		var p := _project(target)
		var radius := 25.0 if not is_3d_preview else 22.0
		var note_rect := Rect2(p - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
		var color: Color = layer_colors.get(layer_name, active_layer_color)
		color.a = opacity * float(layer_opacities.get(layer_name, 0.9))
		draw_rect(note_rect, color, true)
		var outline: Color = layer_colors.get(layer_name, active_layer_color)
		outline.a = color.a
		draw_rect(note_rect, outline, false, 2.0)
		if str(note.get("id", "")) == selected_id or selected_ids.has(str(note.get("id", ""))):
			draw_rect(note_rect.grow(4), Color("#f5cf67"), false, 2.0)
	if line_start.x >= 0.0 and line_preview_position.x >= 0.0:
		var line_color := active_layer_color
		line_color.a = 0.52
		draw_line(_project(line_start), _project(line_preview_position), line_color, 3.0, true)
	if ghost_position.x >= 0.0:
		var ghost := ghost_position
		if snap_enabled and not Input.is_key_pressed(KEY_SHIFT):
			ghost.x = (
				(round(ghost.x * snap_x - grid_offset.x - 0.5) + grid_offset.x + 0.5)
				/ float(snap_x)
			)
			ghost.y = (
				(round(ghost.y * snap_y - grid_offset.y - 0.5) + grid_offset.y + 0.5)
				/ float(snap_y)
			)
		var ghost_color := active_layer_color
		ghost_color.a = 0.35
		var point := _project(ghost)
		draw_rect(Rect2(point - Vector2(19, 19), Vector2(38, 38)), ghost_color, false, 2.0)
	if cursor_position.x >= 0.0:
		var cursor := _project(cursor_position)
		draw_circle(cursor, 10.0, Color(0.52, 0.86, 1.0, 0.28))
		draw_circle(cursor, 4.0, Color("#a8e4ff"))
		draw_circle(cursor, 12.0, Color("#a8e4ff"), false, 1.0)


func refresh() -> void:
	queue_redraw()
