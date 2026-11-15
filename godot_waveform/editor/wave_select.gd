extends Control

signal region_selected(from_ratio: float, to_ratio: float)
signal note_selected(id: String)
signal note_delete_requested(id: String)

var waveform: WaveformView
var viewport_waveform: WaveformView
var notes: Array[Dictionary] = []
var shapes: Array[Dictionary] = []
var markers: Array[Dictionary] = []
var duration := 1.0
var start_offset := 0.0
var selected_ids: Array[String] = []
var visible_layers: Dictionary = {}
var layer_colors: Dictionary = {}
var layer_opacities: Dictionary = {}
var selecting := false
var left_dragging := false
var left_moved := false
var start_x := 0.0
var end_x := 0.0
var left_start_x := 0.0
var start_view := 0.0
var hit_note_id := ""
var bar_seconds := 1.0
var bpm_points: Array[Vector2] = [Vector2(0.0, 128.0), Vector2(1.0, 128.0)]
var fit_only := false
var fit_dragging := false
var fit_panning := false
var fit_pan_last_x := 0.0
var divisions_per_bar := 8
var snap_seek_to_bar := true
var snap_pan_to_bar := true
var spatial_snap_x := 3
var spatial_snap_y := 3


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func cancel_pending_pan() -> void:
	left_dragging = false
	left_moved = false


func _gui_input(event: InputEvent) -> void:
	if fit_only:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				fit_dragging = event.pressed and not event.shift_pressed
				fit_panning = event.pressed and event.shift_pressed
				fit_pan_last_x = event.position.x
				if event.pressed and not event.shift_pressed:
					_seek_minimap_position(event.position.x)
			elif event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
				fit_panning = event.pressed
				fit_pan_last_x = event.position.x
			elif (
				event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
				and event.pressed
			):
				if event.shift_pressed:
					var pan_amount := 0.2 / maxf(waveform.zoom, 1.0)
					waveform.scroll_by(
						-pan_amount if event.button_index == MOUSE_BUTTON_WHEEL_UP else pan_amount
					)
				elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
					waveform.zoom_at(waveform.zoom_step, event.position.x / maxf(size.x, 1.0))
				else:
					waveform.zoom_at(1.0 / waveform.zoom_step, event.position.x / maxf(size.x, 1.0))
			accept_event()
		elif event is InputEventMouseMotion and fit_dragging:
			_seek_minimap_position(event.position.x)
			accept_event()
		elif event is InputEventMouseMotion and fit_panning:
			var visible_span := 1.0 / maxf(waveform.zoom, 1.0)
			var pan_delta := (event.position.x - fit_pan_last_x) / maxf(size.x, 1.0)
			waveform.scroll_by(-pan_delta * visible_span)
			fit_pan_last_x = event.position.x
			accept_event()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				left_dragging = true
				left_moved = false
				left_start_x = event.position.x
				start_view = waveform.view_start
				hit_note_id = _note_at_x(event.position.x)
				accept_event()
			else:
				if left_dragging and not left_moved:
					if not hit_note_id.is_empty():
						note_selected.emit(hit_note_id)
					else:
						var ratio := _ratio(event.position.x)
						waveform.seek_requested.emit(_snap_ratio_to_division(ratio))
				left_dragging = false
				accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				var hit := _note_at_x(event.position.x)
				if not hit.is_empty():
					note_delete_requested.emit(hit)
				else:
					selecting = true
					start_x = event.position.x
					end_x = start_x
					queue_redraw()
			else:
				if selecting:
					var a := _ratio(start_x)
					var b := _ratio(end_x)
					region_selected.emit(minf(a, b), maxf(a, b))
				selecting = false
				queue_redraw()
			accept_event()
		elif (
			event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and event.pressed
		):
			if event.shift_pressed:
				var pan_amount := 0.2 / maxf(waveform.zoom, 1.0)
				waveform.scroll_by(
					-pan_amount if event.button_index == MOUSE_BUTTON_WHEEL_UP else pan_amount
				)
			elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
				waveform.zoom_at(waveform.zoom_step, event.position.x / maxf(size.x, 1.0))
			else:
				waveform.zoom_at(1.0 / waveform.zoom_step, event.position.x / maxf(size.x, 1.0))
			accept_event()
	elif event is InputEventMouseMotion:
		if selecting:
			end_x = event.position.x
			queue_redraw()
		if left_dragging and absf(event.position.x - left_start_x) > 4.0:
			left_moved = true
			var span := 1.0 / maxf(waveform.zoom, 1.0)
			var raw_start := clampf(
				start_view - (event.position.x - left_start_x) / maxf(size.x, 1.0) * span,
				0.0,
				1.0 - span
			)
			if duration > 0.0 and snap_pan_to_bar and not Input.is_key_pressed(KEY_SHIFT):
				var tempo_points := _sorted_bpm_points()
				var snap_beats := 4.0 / float(maxi(divisions_per_bar, 1))
				var beat_count := _beat_count_at_time(raw_start * duration, tempo_points)
				var target_beats: float = float(round(beat_count / snap_beats)) * snap_beats
				raw_start = _time_at_beat(target_beats, tempo_points) / duration
			var snapped_start := clampf(raw_start, 0.0, 1.0 - span)
			if not is_equal_approx(waveform.view_start, snapped_start):
				waveform.view_start = snapped_start
			queue_redraw()
			accept_event()


func _seek_minimap_position(x: float) -> void:
	if waveform != null:
		var visible_span := 1.0 / maxf(waveform.zoom, 1.0)
		var ratio := waveform.view_start + clampf(x / maxf(size.x, 1.0), 0.0, 1.0) * visible_span
		waveform.seek_requested.emit(clampf(ratio, 0.0, 1.0))


func _note_at_x(x: float) -> String:
	if duration <= 0.0:
		return ""
	var span := 1.0 / maxf(waveform.zoom, 1.0)
	var best_distance := 12.0
	var best_id := ""
	for note in notes:
		var layer_name := str(note.get("layer", "Layer 1"))
		if not bool(visible_layers.get(layer_name, true)):
			continue
		var ratio := float(note.get("time", 0.0)) / duration
		var note_x := (ratio - waveform.view_start) / span * size.x
		var distance := absf(note_x - x)
		if distance < best_distance:
			best_distance = distance
			best_id = str(note.get("id", ""))
	return best_id


func _ratio(x: float) -> float:
	if waveform == null:
		return 0.0
	var span := 1.0 / maxf(waveform.zoom, 1.0)
	return clampf(waveform.view_start + clampf(x / maxf(size.x, 1.0), 0.0, 1.0) * span, 0.0, 1.0)


func _snap_ratio_to_division(ratio: float) -> float:
	if duration <= 0.0 or not snap_seek_to_bar or Input.is_key_pressed(KEY_SHIFT):
		return clampf(ratio, 0.0, 1.0)
	var points := _sorted_bpm_points()
	var step_beats := 4.0 / float(maxi(divisions_per_bar, 1))
	var target_beats: float = _beat_count_at_time(ratio * duration, points)
	var snapped_beats: float = round(target_beats / step_beats) * step_beats
	return clampf(_time_at_beat(snapped_beats, points) / duration, 0.0, 1.0)


func _sorted_bpm_points() -> Array[Vector2]:
	var sorted: Array[Vector2] = []
	for point in bpm_points:
		sorted.append(point)
	sorted.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
	return sorted


func _bpm_at_time(time: float, points: Array[Vector2]) -> float:
	if points.is_empty():
		return 240.0 / maxf(bar_seconds, 0.001)
	var ratio := clampf(time / maxf(duration, 0.001), 0.0, 1.0)
	if ratio <= points[0].x:
		return maxf(points[0].y, 1.0)
	for index in range(points.size() - 1):
		var left: Vector2 = points[index]
		var right: Vector2 = points[index + 1]
		if ratio <= right.x:
			var width := maxf(right.x - left.x, 0.000001)
			return maxf(lerpf(left.y, right.y, (ratio - left.x) / width), 1.0)
	return maxf(points[-1].y, 1.0)


func _beat_count_at_time(time: float, points: Array[Vector2]) -> float:
	return _raw_beat_count_at_time(time, points) - _raw_beat_count_at_time(start_offset, points)


func _raw_beat_count_at_time(time: float, points: Array[Vector2]) -> float:
	var end_time := clampf(time, 0.0, duration)
	var boundaries: Array[float] = [0.0, end_time]
	for point in points:
		var point_time := clampf(point.x, 0.0, 1.0) * duration
		if point_time > 0.0 and point_time < end_time:
			boundaries.append(point_time)
	boundaries.sort()
	var beats := 0.0
	for index in range(boundaries.size() - 1):
		var left_time: float = boundaries[index]
		var right_time: float = boundaries[index + 1]
		var average_bpm := (
			(_bpm_at_time(left_time, points) + _bpm_at_time(right_time, points)) * 0.5
		)
		beats += average_bpm * (right_time - left_time) / 60.0
	return beats


func _time_at_beat(target_beats: float, points: Array[Vector2]) -> float:
	var absolute_target := target_beats + _raw_beat_count_at_time(start_offset, points)
	if absolute_target <= 0.0:
		return 0.0
	var low := 0.0
	var high := duration
	for _iteration in range(22):
		var midpoint := (low + high) * 0.5
		if _raw_beat_count_at_time(midpoint, points) < absolute_target:
			low = midpoint
		else:
			high = midpoint
	return (low + high) * 0.5


func _is_default_shape_label(value: String, shape_type: String) -> bool:
	var parts := value.strip_edges().split(" ", false)
	return (
		value.strip_edges().is_empty()
		or (
			parts.size() == 2
			and parts[0].to_lower() in [shape_type.to_lower(), "shape"]
			and parts[1].is_valid_int()
		)
	)


func _shape_position_at(points: Array, progress: float, is_curve: bool) -> Vector2:
	if points.size() == 1:
		return points[0]
	var scaled := clampf(progress, 0.0, 1.0) * float(points.size() - 1)
	var segment := mini(int(floor(scaled)), points.size() - 2)
	var t := scaled - float(segment)
	var p1: Vector2 = points[segment]
	var p2: Vector2 = points[segment + 1]
	if not is_curve:
		return p1.lerp(p2, t)
	var p0: Vector2 = points[maxi(segment - 1, 0)]
	var p3: Vector2 = points[mini(segment + 2, points.size() - 1)]
	var t2 := t * t
	var t3 := t2 * t
	return (
		0.5
		* (
			(2.0 * p1)
			+ (-p0 + p2) * t
			+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
		)
	)


func _draw() -> void:
	if fit_only:
		if viewport_waveform != null and waveform != null:
			var viewport_mini_span := 1.0 / maxf(waveform.zoom, 1.0)
			var main_span := 1.0 / maxf(viewport_waveform.zoom, 1.0)
			var left := (
				(viewport_waveform.view_start - waveform.view_start) / viewport_mini_span * size.x
			)
			var right := (
				(viewport_waveform.view_start + main_span - waveform.view_start)
				/ viewport_mini_span
				* size.x
			)
			var visible_left := clampf(left, 0.0, size.x)
			var visible_right := clampf(right, 0.0, size.x)
			if visible_right > visible_left:
				var viewport_rect := Rect2(
					visible_left, 1.0, visible_right - visible_left, maxf(size.y - 2.0, 0.0)
				)
				draw_rect(viewport_rect, Color(0.78, 0.5, 1.0, 0.16), true)
				draw_rect(viewport_rect, Color("#d9aaff", 0.9), false, 1.0)
		var mini_span := 1.0 / maxf(waveform.zoom, 1.0) if waveform != null else 1.0
		var mini_start := waveform.view_start if waveform != null else 0.0
		for marker in markers:
			var marker_ratio := float(marker.get("time", 0.0)) / maxf(duration, 0.01)
			if marker_ratio < mini_start or marker_ratio > mini_start + mini_span:
				continue
			var marker_x := (marker_ratio - mini_start) / mini_span * size.x
			draw_line(
				Vector2(marker_x, 0),
				Vector2(marker_x, size.y),
				Color(marker.get("color", Color("#e6c45e"))),
				2.0,
				true
			)
		return
	if waveform != null and duration > 0.0:
		var visible_span := 1.0 / maxf(waveform.zoom, 1.0)
		var visible_start := waveform.view_start * duration
		var visible_end := minf((waveform.view_start + visible_span) * duration, duration)
		var tempo_points := _sorted_bpm_points()
		var step_beats := 4.0 / float(maxi(divisions_per_bar, 1))
		var first_step := floori(_beat_count_at_time(visible_start, tempo_points) / step_beats)
		var last_step := ceili(_beat_count_at_time(visible_end, tempo_points) / step_beats)
		var total_steps := maxi(last_step - first_step + 1, 1)
		var bar_stride := maxi(divisions_per_bar, 1)
		var minor_stride := maxi(ceili(float(total_steps) / maxf(size.x / 5.0, 1.0)), 1)
		var first_minor := floori(float(first_step) / float(minor_stride)) * minor_stride
		for step_index in range(first_minor, last_step + 1, minor_stride):
			if posmod(step_index, bar_stride) == 0:
				continue
			var time := _time_at_beat(float(step_index) * step_beats, tempo_points)
			if time < visible_start or time > visible_end:
				continue
			var x := (time / duration - waveform.view_start) / visible_span * size.x
			draw_line(
				Vector2(x, size.y * 0.75), Vector2(x, size.y), Color(0.82, 0.88, 1.0, 0.22), 1.0
			)
		var first_bar := floori(float(first_step) / float(bar_stride))
		var last_bar := ceili(float(last_step) / float(bar_stride))
		var bar_count := maxi(last_bar - first_bar + 1, 1)
		var bar_draw_stride := maxi(ceili(float(bar_count) / maxf(size.x / 12.0, 1.0)), 1)
		var first_drawn_bar := floori(float(first_bar) / float(bar_draw_stride)) * bar_draw_stride
		for bar_index in range(first_drawn_bar, last_bar + 1, bar_draw_stride):
			var time := _time_at_beat(float(bar_index * bar_stride) * step_beats, tempo_points)
			if time < visible_start or time > visible_end:
				continue
			var x := (time / duration - waveform.view_start) / visible_span * size.x
			draw_line(Vector2(x, size.y * 0.5), Vector2(x, size.y), Color(1.0, 1.0, 1.0, 0.48), 2.0)
		var ordered_notes: Array[Dictionary] = []
		for candidate in notes:
			ordered_notes.append(candidate)
		ordered_notes.sort_custom(
			func(a: Dictionary, b: Dictionary):
				return float(a.get("time", 0.0)) < float(b.get("time", 0.0))
		)
		for note_index in range(ordered_notes.size()):
			var note: Dictionary = ordered_notes[note_index]
			var layer_name := str(note.get("layer", "Layer 1"))
			if not bool(visible_layers.get(layer_name, true)):
				continue
			var ratio := float(note.get("time", 0.0)) / duration
			if ratio < waveform.view_start or ratio > waveform.view_start + visible_span:
				continue
			var x := (ratio - waveform.view_start) / visible_span * size.x
			var layer_color: Color = layer_colors.get(layer_name, Color("#BE78F4"))
			var opacity := float(layer_opacities.get(layer_name, 0.9))
			var selected := selected_ids.has(str(note.get("id", "")))
			var outline := Color.WHITE if selected else layer_color
			var nearest_spacing := size.x
			if note_index > 0:
				var previous_ratio := (
					float(ordered_notes[note_index - 1].get("time", 0.0)) / duration
				)
				var previous_x := (previous_ratio - waveform.view_start) / visible_span * size.x
				nearest_spacing = minf(nearest_spacing, absf(x - previous_x))
			if note_index + 1 < ordered_notes.size():
				var next_ratio := float(ordered_notes[note_index + 1].get("time", 0.0)) / duration
				var next_x := (next_ratio - waveform.view_start) / visible_span * size.x
				nearest_spacing = minf(nearest_spacing, absf(next_x - x))
			var box_size := clampf(nearest_spacing * 0.8, 4.0, 28.0)
			var box := Rect2(x - box_size * 0.5, size.y * 0.48 - box_size * 0.5, box_size, box_size)
			draw_rect(box, Color(0.035, 0.04, 0.06, 0.28), true)
			draw_rect(box, outline, false, 1.5 if selected else 1.0)
			var note_x := float(note.get("x", 0.5))
			var note_y := float(note.get("y", 0.5))
			var active_x := clampi(int(floor(note_x * 3.0)), 0, 2)
			var active_y := clampi(int(floor(note_y * 3.0)), 0, 2)
			var grid_x := float(maxi(spatial_snap_x, 1))
			var grid_y := float(maxi(spatial_snap_y, 1))
			var snapped_note_x := (round(note_x * grid_x - 0.5) + 0.5) / grid_x
			var snapped_note_y := (round(note_y * grid_y - 0.5) + 0.5) / grid_y
			var is_quantized := (
				absf(note_x - snapped_note_x) < 0.002 and absf(note_y - snapped_note_y) < 0.002
			)
			if box_size >= 8.0:
				var cell_size := box_size / 3.0
				for cell_y in range(3):
					for cell_x in range(3):
						var cell := Rect2(
							box.position + Vector2(cell_x, cell_y) * cell_size,
							Vector2.ONE * cell_size
						)
						var active_cell := cell_x == active_x and cell_y == active_y
						var cell_color := Color(
							layer_color.r,
							layer_color.g,
							layer_color.b,
							opacity * (0.95 if active_cell else 0.34)
						)
						if active_cell and is_quantized:
							draw_rect(cell.grow(-1.0), cell_color, true)
						draw_rect(
							cell,
							Color(layer_color.r, layer_color.g, layer_color.b, 0.48),
							false,
							0.7
						)
			else:
				draw_rect(box.grow(-1.0), Color(layer_color, opacity * 0.8), true)
			var precise_center := box.position + Vector2(note_x, note_y) * box.size
			var position_color := Color.WHITE if selected else Color("#f5cf67")
			if is_quantized:
				draw_circle(precise_center, 2.4, position_color)
			else:
				draw_circle(precise_center, 3.2, Color("#0F1013"))
				draw_circle(precise_center, 2.5, position_color, false, 1.1, true)
				draw_line(
					precise_center + Vector2(-4.0, 0.0),
					precise_center + Vector2(4.0, 0.0),
					position_color,
					0.8,
					true
				)
				draw_line(
					precise_center + Vector2(0.0, -4.0),
					precise_center + Vector2(0.0, 4.0),
					position_color,
					0.8,
					true
				)
			if box_size >= 18.0:
				var note_number := note_index + 1
				var note_label := str(note.get("name", "")).strip_edges()
				if note_label.is_empty():
					note_label = "Note %d" % note_number
				var label_color := Color.WHITE if selected else Color(0.85, 0.88, 0.94, 0.9)
				draw_string(
					ThemeDB.fallback_font,
					Vector2(x - 52.0, box.position.y - 2.0),
					note_label,
					HORIZONTAL_ALIGNMENT_CENTER,
					72.0,
					10,
					label_color
				)
		var ordered_shapes: Array[Dictionary] = []
		for shape in shapes:
			ordered_shapes.append(shape)
		ordered_shapes.sort_custom(
			func(a: Dictionary, b: Dictionary):
				var a_time := float(a.get("time", 0.0))
				var b_time := float(b.get("time", 0.0))
				return a_time < b_time
		)
		for shape_index in range(ordered_shapes.size()):
			var shape: Dictionary = ordered_shapes[shape_index]
			var layer_name := str(shape.get("layer", "Layer 1"))
			if not bool(visible_layers.get(layer_name, true)):
				continue
			var points: Array = shape.get("points", [])
			if points.size() < 2:
				continue
			var shape_time := float(shape.get("time", 0.0))
			var shape_duration := maxf(float(shape.get("duration", bar_seconds)), 0.001)
			var divisions := maxi(int(shape.get("beat_division", divisions_per_bar)), 1)
			var layer_color: Color = layer_colors.get(layer_name, Color("#BE78F4"))
			var opacity := float(layer_opacities.get(layer_name, 0.9))
			var is_selected := selected_ids.has(str(shape.get("id", "")))
			var label := str(shape.get("name", ""))
			if _is_default_shape_label(label, str(shape.get("type", "Shape"))):
				label = "%s %d" % [str(shape.get("type", "Shape")), shape_index + 1]
			else:
				label += " (%d)" % (shape_index + 1)
			var tile_y := size.y * 0.48
			var span_from := maxf(shape_time, visible_start)
			var span_to := minf(shape_time + shape_duration, visible_end)
			if span_to > span_from:
				var left_x := (span_from / duration - waveform.view_start) / visible_span * size.x
				var right_x := (span_to / duration - waveform.view_start) / visible_span * size.x
				draw_rect(
					Rect2(left_x, tile_y - 3.0, right_x - left_x, 6.0),
					Color(layer_color, opacity * 0.25),
					true
				)
			for division_index in range(divisions):
				var event_time := (
					shape_time + shape_duration * float(division_index) / float(divisions)
				)
				var ratio := event_time / duration
				if ratio < waveform.view_start or ratio > waveform.view_start + visible_span:
					continue
				var position := _shape_position_at(
					points,
					float(division_index) / float(divisions),
					str(shape.get("type", "")) == "Curve"
				)
				if bool(shape.get("snap_to_grid", true)):
					var grid_division := float(maxi(int(shape.get("grid_division", 3)), 1))
					position.x = (round(position.x * grid_division - 0.5) + 0.5) / grid_division
					position.y = (round(position.y * grid_division - 0.5) + 0.5) / grid_division
				var x := (ratio - waveform.view_start) / visible_span * size.x
				var spacing_px := (
					size.x * shape_duration / duration / visible_span / float(divisions)
				)
				var tile_size := clampf(spacing_px * 0.72, 8.0, 26.0)
				var tile := Rect2(
					x - tile_size * 0.5, tile_y - tile_size * 0.5, tile_size, tile_size
				)
				var fill_color := Color(layer_color, opacity * 0.34)
				draw_rect(tile, fill_color, true)
				draw_rect(
					tile,
					Color.WHITE if is_selected else Color(layer_color, 0.9),
					false,
					1.2 if is_selected else 0.9
				)
				var cell_size := tile_size / 3.0
				var active_x := clampi(int(floor(position.x * 3.0)), 0, 2)
				var active_y := clampi(int(floor(position.y * 3.0)), 0, 2)
				var active_rect := Rect2(
					tile.position + Vector2(active_x, active_y) * cell_size, Vector2.ONE * cell_size
				)
				draw_rect(active_rect.grow(-0.7), Color(layer_color, opacity * 0.85), true)
				if division_index == 0 and tile_size >= 20.0:
					draw_string(
						ThemeDB.fallback_font,
						Vector2(x - 35.0, tile.position.y - 2.0),
						label,
						HORIZONTAL_ALIGNMENT_CENTER,
						70.0,
						9,
						Color.WHITE if is_selected else Color(layer_color, 0.9)
					)
		for marker in markers:
			var ratio := float(marker.get("time", 0.0)) / duration
			if ratio < waveform.view_start or ratio > waveform.view_start + visible_span:
				continue
			var x: float = (ratio - waveform.view_start) / visible_span * size.x
			draw_line(
				Vector2(x, 0),
				Vector2(x, size.y),
				Color(marker.get("color", Color("#e6c45e")), 0.9),
				1.5
			)
	if selecting:
		var left := minf(start_x, end_x)
		var width := absf(end_x - start_x)
		draw_rect(Rect2(left, 0, width, size.y), Color(0.75, 0.52, 1.0, 0.22), true)
		draw_rect(Rect2(left, 0, width, size.y), Color("#BE78F4"), false, 1.5)
