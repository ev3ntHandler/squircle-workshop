extends Control
class_name BeatGridCanvas

signal grid_clicked(position: Vector2)
signal grid_dragged(position: Vector2)

var notes: Array[Dictionary] = []
var selected_id := ""
var selected_ids: Array[String] = []
var cursor_position := Vector2(-1.0, -1.0)
var is_3d_preview := false
var snap_x := 3
var snap_y := 3
var grid_offset := Vector2.ZERO
var active_layer_color := Color("d779fa")
var visible_layers: Dictionary = {"Layer 1": true}
var layer_colors: Dictionary = {"Layer 1": Color("d779fa")}
var layer_opacities: Dictionary = {"Layer 1": 0.9}


func _ready() -> void:
	custom_minimum_size = Vector2(320, 320)
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var drag_pos := Vector2(
			clampf(event.position.x / size.x, 0.0, 1.0), clampf(event.position.y / size.y, 0.0, 1.0)
		)
		grid_dragged.emit(drag_pos)
	elif (
		event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed
	):
		var pos := Vector2(
			clampf(event.position.x / size.x, 0.0, 1.0), clampf(event.position.y / size.y, 0.0, 1.0)
		)
		grid_clicked.emit(pos)
		accept_event()


func _project(point: Vector2) -> Vector2:
	if not is_3d_preview:
		return point * size
	var top_left := Vector2(size.x * 0.16, size.y * 0.12)
	var top_right := Vector2(size.x * 0.84, size.y * 0.12)
	var bottom_left := Vector2(size.x * 0.04, size.y * 0.92)
	var bottom_right := Vector2(size.x * 0.96, size.y * 0.92)
	return top_left.lerp(top_right, point.x).lerp(bottom_left.lerp(bottom_right, point.x), point.y)


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color("#0b0d11"), true)
	var top_left := _project(Vector2.ZERO)
	var top_right := _project(Vector2.RIGHT)
	var bottom_left := _project(Vector2.DOWN)
	var bottom_right := _project(Vector2.ONE)
	draw_colored_polygon(
		PackedVector2Array([top_left, top_right, bottom_right, bottom_left]), Color("#11151d")
	)
	for i in range(4):
		var fraction := i / 3.0
		draw_line(
			_project(Vector2(fraction, 0)),
			_project(Vector2(fraction, 1)),
			Color(0.36, 0.4, 0.48, 0.55),
			1.0
		)
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
			var label := ["Q", "W", "E", "A", "S", "D", "Z", "X", "C"][index]
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
	for note in notes:
		if not bool(visible_layers.get(str(note.get("layer", "Layer 1")), true)):
			continue
		var normalized := Vector2(float(note.get("x", 0.5)), float(note.get("y", 0.5)))
		var p := _project(normalized)
		var radius := 15.0 if is_3d_preview else 20.0
		var note_rect := Rect2(p - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
		var color: Color = layer_colors.get(str(note.get("layer", "Layer 1")), active_layer_color)
		color.a = 0.22 * float(layer_opacities.get(str(note.get("layer", "Layer 1")), 0.9))
		draw_rect(note_rect, color, true)
		draw_rect(
			note_rect,
			Color(layer_colors.get(str(note.get("layer", "Layer 1")), active_layer_color), 0.95),
			false,
			2.0
		)
		draw_circle(p, 5.0 if is_3d_preview else 6.0, Color.WHITE)
		if str(note.get("id", "")) == selected_id or selected_ids.has(str(note.get("id", ""))):
			draw_rect(note_rect.grow(4), Color("#f5cf67"), false, 2.0)
	if cursor_position.x >= 0.0:
		var cursor := _project(cursor_position)
		draw_circle(cursor, 10.0, Color(0.52, 0.86, 1.0, 0.28))
		draw_circle(cursor, 4.0, Color("#a8e4ff"))
		draw_circle(cursor, 12.0, Color("#a8e4ff"), false, 1.0)


func refresh() -> void:
	queue_redraw()
