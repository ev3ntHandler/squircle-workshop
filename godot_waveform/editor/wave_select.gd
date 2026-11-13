extends Control

signal region_selected(from_ratio: float, to_ratio: float)
signal note_selected(id: String)
signal note_delete_requested(id: String)

var waveform: WaveformView
var notes: Array[Dictionary] = []
var markers: Array[Dictionary] = []
var duration := 1.0
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
var divisions_per_bar := 8
var pan_target_start := 0.0
var pan_target_active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(true)
	if waveform != null:
		pan_target_start = waveform.view_start


func _process(delta: float) -> void:
	if fit_only:
		return
	if pan_target_active and waveform != null:
		var distance := absf(waveform.view_start - pan_target_start)
		if distance < 0.00001:
			waveform.view_start = pan_target_start
			pan_target_active = false
		else:
			var blend := 1.0 - exp(-delta * 18.0)
			waveform.view_start = lerpf(waveform.view_start, pan_target_start, blend)


func _gui_input(event: InputEvent) -> void:
	if fit_only:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				fit_dragging = event.pressed
				if event.pressed:
					_seek_minimap_position(event.position.x)
			accept_event()
		elif event is InputEventMouseMotion and fit_dragging:
			_seek_minimap_position(event.position.x)
			accept_event()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				left_dragging = true
				left_moved = false
				left_start_x = event.position.x
				start_view = waveform.view_start
				pan_target_start = waveform.view_start
				pan_target_active = false
				hit_note_id = _note_at_x(event.position.x)
				accept_event()
			else:
				if left_dragging and not left_moved:
					if not hit_note_id.is_empty():
						note_selected.emit(hit_note_id)
					else:
						var ratio := _ratio(event.position.x)
						waveform.seek_requested.emit(ratio)
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
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			waveform.zoom_at(waveform.zoom_step, event.position.x / maxf(size.x, 1.0))
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
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
			if duration > 0.0:
				var tempo_points := _sorted_bpm_points()
				var target_beats := (
					round(_beat_count_at_time(raw_start * duration, tempo_points) / 4.0) * 4.0
				)
				raw_start = _time_at_beat(target_beats, tempo_points) / duration
			pan_target_start = clampf(raw_start, 0.0, 1.0 - span)
			pan_target_active = true
			queue_redraw()
			accept_event()


func _seek_minimap_position(x: float) -> void:
	if waveform != null:
		waveform.seek_requested.emit(clampf(x / maxf(size.x, 1.0), 0.0, 1.0))


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
	if target_beats <= 0.0:
		return 0.0
	var low := 0.0
	var high := duration
	for _iteration in range(22):
		var midpoint := (low + high) * 0.5
		if _beat_count_at_time(midpoint, points) < target_beats:
			low = midpoint
		else:
			high = midpoint
	return (low + high) * 0.5


func _draw() -> void:
	if fit_only:
		return
	if waveform != null and duration > 0.0:
		var visible_span := 1.0 / maxf(waveform.zoom, 1.0)
		var visible_start := waveform.view_start * duration
		var visible_end := minf((waveform.view_start + visible_span) * duration, duration)
		var tempo_points := _sorted_bpm_points()
		var step_beats := 4.0 / float(maxi(divisions_per_bar, 1))
		var first_step := floori(_beat_count_at_time(visible_start, tempo_points) / step_beats)
		var last_step := ceili(_beat_count_at_time(visible_end, tempo_points) / step_beats)
		for step_index in range(first_step, last_step + 1):
			var time := _time_at_beat(float(step_index) * step_beats, tempo_points)
			if time < visible_start or time > visible_end:
				continue
			var x := (time / duration - waveform.view_start) / visible_span * size.x
			var is_bar := step_index % maxi(divisions_per_bar, 1) == 0
			var y_start := size.y * (0.5 if is_bar else 0.75)
			var color := Color(1.0, 1.0, 1.0, 0.48) if is_bar else Color(0.82, 0.88, 1.0, 0.22)
			draw_line(Vector2(x, y_start), Vector2(x, size.y), color, 2.0 if is_bar else 1.0)
		for note in notes:
			var layer_name := str(note.get("layer", "Layer 1"))
			if not bool(visible_layers.get(layer_name, true)):
				continue
			var ratio := float(note.get("time", 0.0)) / duration
			if ratio < waveform.view_start or ratio > waveform.view_start + visible_span:
				continue
			var x := (ratio - waveform.view_start) / visible_span * size.x
			var color: Color = layer_colors.get(layer_name, Color("#c77dff"))
			color.a = 0.6 * float(layer_opacities.get(layer_name, 0.9))
			draw_rect(Rect2(x - 3.0, size.y * 0.19, 6.0, size.y * 0.62), color, true)
			if selected_ids.has(str(note.get("id", ""))):
				draw_line(Vector2(x, 0), Vector2(x, size.y), Color("#f5cf67"), 2.0)
		for marker in markers:
			var ratio := float(marker.get("time", 0.0)) / duration
			if ratio < waveform.view_start or ratio > waveform.view_start + visible_span:
				continue
			var x := (ratio - waveform.view_start) / visible_span * size.x
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
		draw_rect(Rect2(left, 0, width, size.y), Color("#c77dff"), false, 1.5)
