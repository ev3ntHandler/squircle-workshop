extends Control

signal points_changed(points: Array)

var points: Array[Vector2] = [Vector2(0, 128), Vector2(1, 128)]
var selected := -1
var dragging := false
var min_bpm := 40.0
var max_bpm := 300.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var nearest := -1
			var distance := 22.0
			for i in range(points.size()):
				var d := _pixel(points[i]).distance_to(event.position)
				if d < distance:
					distance = d
					nearest = i
			if nearest >= 0:
				selected = nearest
			else:
				points.append(_value(event.position))
				_sort_points()
				selected = _nearest_index(_value(event.position).x)
			dragging = true
			accept_event()
		else:
			dragging = false
			points_changed.emit(points)
			accept_event()
	elif (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_RIGHT
		and event.pressed
	):
		var nearest := _nearest_index(_value(event.position).x)
		if nearest > 0 and nearest < points.size() - 1:
			points.remove_at(nearest)
			points_changed.emit(points)
			queue_redraw()
		accept_event()
	elif event is InputEventMouseMotion and dragging and selected >= 0:
		var value := _value(event.position)
		if selected > 0 and selected < points.size() - 1:
			value.x = clampf(
				value.x, points[selected - 1].x + 0.005, points[selected + 1].x - 0.005
			)
		else:
			value.x = points[selected].x
		points[selected] = value
		queue_redraw()
		points_changed.emit(points)
		accept_event()


func _value(pos: Vector2) -> Vector2:
	return Vector2(
		clampf(pos.x / maxf(size.x, 1.0), 0.0, 1.0),
		lerpf(max_bpm, min_bpm, clampf(pos.y / maxf(size.y, 1.0), 0.0, 1.0))
	)


func _pixel(point: Vector2) -> Vector2:
	return Vector2(point.x * size.x, inverse_lerp(max_bpm, min_bpm, point.y) * size.y)


func _nearest_index(x: float) -> int:
	var index := 0
	var delta := 10.0
	for i in range(points.size()):
		var d := absf(points[i].x - x)
		if d < delta:
			delta = d
			index = i
	return index


func _sort_points() -> void:
	points.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.025, 0.035, 0.06, 0.82), true)
	for i in range(1, 5):
		var y := size.y * i / 5.0
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.55, 0.62, 0.77, 0.18), 1.0)
	var sorted := points.duplicate()
	sorted.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
	for i in range(sorted.size() - 1):
		draw_line(_pixel(sorted[i]), _pixel(sorted[i + 1]), Color("#7ce0d2"), 3.0)
	for i in range(sorted.size()):
		var pos := _pixel(sorted[i])
		draw_circle(pos, 7.0, Color("#0c121a"))
		draw_circle(pos, 5.0, Color("#f0d676") if i == selected else Color("#7ce0d2"))
		draw_string(
			ThemeDB.fallback_font,
			pos + Vector2(10, -7),
			"%.2f" % sorted[i].y,
			HORIZONTAL_ALIGNMENT_LEFT,
			80,
			11,
			Color.WHITE
		)
	draw_string(
		ThemeDB.fallback_font,
		Vector2(12, 19),
		"BPM AUTOMATION  ·  Click to add · Drag to edit · Right click to remove",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		10,
		Color("#dce6f3")
	)
