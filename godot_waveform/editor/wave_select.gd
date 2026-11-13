extends Control

signal region_selected(from_ratio: float, to_ratio: float)
signal waveform_clicked(ratio: float)

var waveform: WaveformView
var notes: Array[Dictionary] = []
var markers: Array[Dictionary] = []
var duration := 1.0
var selected_ids: Array[String] = []
var visible_layers: Dictionary = {}
var layer_colors: Dictionary = {}
var layer_opacities: Dictionary = {}
var selecting := false
var start_x := 0.0
var end_x := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
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
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not selecting:
			waveform_clicked.emit(_ratio(event.position.x))
			waveform.seek_requested.emit(_ratio(event.position.x))
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


func _ratio(x: float) -> float:
	if waveform == null:
		return 0.0
	var span := 1.0 / maxf(waveform.zoom, 1.0)
	return clampf(waveform.view_start + clampf(x / maxf(size.x, 1.0), 0.0, 1.0) * span, 0.0, 1.0)


func _draw() -> void:
	if waveform != null and duration > 0.0:
		var visible_span := 1.0 / maxf(waveform.zoom, 1.0)
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
