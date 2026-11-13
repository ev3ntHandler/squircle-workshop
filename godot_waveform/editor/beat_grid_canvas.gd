extends Control
class_name BeatGridCanvas

signal grid_clicked(position: Vector2, ctrl_pressed: bool)
signal grid_dragged(position: Vector2)
signal grid_hovered(position: Vector2)
signal note_delete_requested(id: String)
signal line_completed(start: Vector2, finish: Vector2)
signal shape_selected(id: String)
signal shape_point_edit_started(id: String)
signal shape_point_changed(id: String, point_index: int, position: Vector2)
signal shape_point_edit_finished(id: String)

var notes: Array[Dictionary] = []
var shapes: Array[Dictionary] = []
var selected_shape_id := ""
var dragging_shape_id := ""
var dragging_shape_point := -1
var interactive := true
var line_preview_duration := 1.0
var active_layer_opacity := 0.9
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
	if not interactive and event is InputEventMouseButton:
		accept_event()
		return
	if event is InputEventMouseMotion:
		var hover := _normalized_position(event.position)
		ghost_position = hover
		grid_hovered.emit(hover)
		if not dragging_shape_id.is_empty() and dragging_shape_point >= 0:
			shape_point_changed.emit(dragging_shape_id, dragging_shape_point, hover)
			accept_event()
			queue_redraw()
			return
		if line_dragging:
			line_preview_position = hover
			accept_event()
		elif interactive and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			grid_dragged.emit(hover)
		if right_dragging and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_delete_notes_along_segment(right_drag_last, event.position)
			right_drag_last = event.position
			accept_event()
		queue_redraw()
	elif event is InputEventMouseButton:
		var pos := _normalized_position(event.position)
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and active_tool == "Select":
				var point_hit := _shape_point_at(event.position)
				if point_hit.size() == 2:
					dragging_shape_id = str(point_hit[0])
					dragging_shape_point = int(point_hit[1])
					shape_point_edit_started.emit(dragging_shape_id)
					accept_event()
					return
				var hit_shape := _shape_at(event.position)
				if not hit_shape.is_empty():
					shape_selected.emit(hit_shape)
					accept_event()
					return
			if not event.pressed and not dragging_shape_id.is_empty():
				var finished_id := dragging_shape_id
				dragging_shape_id = ""
				dragging_shape_point = -1
				shape_point_edit_finished.emit(finished_id)
				accept_event()
				return
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


func _shape_point_at(pixel_position: Vector2) -> Array:
	for shape in shapes:
		if str(shape.get("id", "")) != selected_shape_id:
			continue
		var points: Array = shape.get("points", [])
		for index in range(points.size()):
			if _project(points[index]).distance_to(pixel_position) <= 18.0:
				return [selected_shape_id, index]
	return []


func _shape_at(pixel_position: Vector2) -> String:
	var closest_id := ""
	var closest_distance := 14.0
	for shape in shapes:
		var samples := _shape_samples(shape)
		if (
			samples.size() == 1
			and _project(samples[0]).distance_to(pixel_position) < closest_distance
		):
			closest_id = str(shape.get("id", ""))
			closest_distance = _project(samples[0]).distance_to(pixel_position)
		for index in range(samples.size() - 1):
			var a := _project(samples[index])
			var b := _project(samples[index + 1])
			var distance := (
				Geometry2D
				. get_closest_point_to_segment(pixel_position, a, b)
				. distance_to(pixel_position)
			)
			if distance < closest_distance:
				closest_id = str(shape.get("id", ""))
				closest_distance = distance
	return closest_id


func _shape_samples(shape: Dictionary) -> Array[Vector2]:
	var points: Array = shape.get("points", [])
	var result: Array[Vector2] = []
	if points.is_empty():
		return result
	if points.size() == 1:
		result.append(points[0])
		return result
	var is_curve := str(shape.get("type", "")) == "Curve"
	for segment in range(points.size() - 1):
		for subdivision in range(9):
			if segment > 0 and subdivision == 0:
				continue
			var t := float(subdivision) / 8.0
			if is_curve and points.size() >= 3:
				var p0: Vector2 = points[maxi(segment - 1, 0)]
				var p1: Vector2 = points[segment]
				var p2: Vector2 = points[segment + 1]
				var p3: Vector2 = points[mini(segment + 2, points.size() - 1)]
				var t2 := t * t
				var t3 := t2 * t
				result.append(
					(
						0.5
						* (
							(2.0 * p1)
							+ (-p0 + p2) * t
							+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
							+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
						)
					)
				)
			else:
				result.append(points[segment].lerp(points[segment + 1], t))
	return result


func _snap_preview_point(point: Vector2) -> Vector2:
	if not snap_enabled or Input.is_key_pressed(KEY_SHIFT):
		return point
	point.x = (round(point.x * snap_x - grid_offset.x - 0.5) + grid_offset.x + 0.5) / float(snap_x)
	point.y = (round(point.y * snap_y - grid_offset.y - 0.5) + grid_offset.y + 0.5) / float(snap_y)
	return Vector2(clampf(point.x, 0.02, 0.98), clampf(point.y, 0.02, 0.98))


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
		var growth := lerpf(0.42, 1.0, opacity) if animate_notes else 1.0
		var radius := (25.0 if not is_3d_preview else 22.0) * growth
		var note_rect := Rect2(p - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
		var color: Color = layer_colors.get(layer_name, active_layer_color)
		color.a = opacity * float(layer_opacities.get(layer_name, 0.9))
		draw_rect(note_rect, color, true)
		var outline: Color = layer_colors.get(layer_name, active_layer_color)
		outline.a = color.a
		draw_rect(note_rect, outline, false, 2.0)
		if str(note.get("id", "")) == selected_id or selected_ids.has(str(note.get("id", ""))):
			draw_rect(note_rect.grow(4), Color("#f5cf67"), false, 2.0)
	for shape in shapes:
		var shape_id := str(shape.get("id", ""))
		var samples := _shape_samples(shape)
		if samples.is_empty():
			continue
		var layer_name := str(shape.get("layer", "Layer 1"))
		if not bool(visible_layers.get(layer_name, true)):
			continue
		var shape_start := float(shape.get("time", 0.0))
		var shape_duration := maxf(float(shape.get("duration", 1.0)), 0.001)
		for sample_index in range(samples.size()):
			var progress := float(sample_index) / float(maxi(samples.size() - 1, 1))
			var arrival := shape_start + progress * shape_duration - current_time
			var opacity := 1.0
			if animate_notes:
				if arrival < 0.0 or arrival > approach_window:
					continue
				opacity = clampf(1.0 - arrival / approach_window, 0.02, 1.0)
			var growth := lerpf(0.42, 1.0, opacity) if animate_notes else 1.0
			var radius := (25.0 if not is_3d_preview else 22.0) * growth
			var center := _project(samples[sample_index])
			var rect := Rect2(center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
			var color: Color = layer_colors.get(layer_name, active_layer_color)
			color.a = opacity * float(layer_opacities.get(layer_name, 0.9))
			draw_rect(rect, color, true)
			if shape_id == selected_shape_id:
				draw_rect(rect.grow(3.0), Color("#f5cf67", 0.9), false, 1.5)
		if shape_id == selected_shape_id:
			var control_points: Array = shape.get("points", [])
			for index in range(control_points.size()):
				var handle := _project(control_points[index])
				draw_circle(handle, 7.0, Color("#f5cf67"))
				draw_circle(handle, 3.0, Color("#17191e"))
	if line_start.x >= 0.0 and line_preview_position.x >= 0.0:
		var snapped_start := _snap_preview_point(line_start)
		var snapped_end := _snap_preview_point(line_preview_position)
		for preview_index in range(9):
			var amount := float(preview_index) / 8.0
			var preview_point := snapped_start.lerp(snapped_end, amount)
			var arrival := amount * line_preview_duration
			var opacity := 1.0
			if animate_notes:
				opacity = clampf(1.0 - arrival / approach_window, 0.02, 1.0)
			var growth := lerpf(0.42, 1.0, opacity) if animate_notes else 1.0
			var radius := (25.0 if not is_3d_preview else 22.0) * growth
			var preview_center := _project(preview_point)
			var rect := Rect2(
				preview_center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0)
			)
			var preview_color := active_layer_color
			preview_color.a = opacity * active_layer_opacity * 0.28
			draw_rect(rect, preview_color, true)
			draw_rect(rect.grow(3.0), Color("#f5cf67", 0.8), false, 1.5)
		draw_circle(_project(snapped_start), 7.0, Color("#f5cf67"))
		draw_circle(_project(snapped_end), 7.0, Color("#f5cf67"))
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
