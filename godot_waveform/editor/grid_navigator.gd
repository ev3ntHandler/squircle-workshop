class_name GridNavigator
extends Control

signal view_changed(center: Vector2, zoom: float)

var center := Vector2(0.5, 0.5)
var zoom := 1.0
var dragging := false
var drag_start := Vector2.ZERO
var drag_center := Vector2.ZERO
var moved := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(92, 76)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.double_click:
				center = Vector2(0.5, 0.5)
				zoom = 1.0
				view_changed.emit(center, zoom)
				queue_redraw()
				accept_event()
				return
			dragging = true
			moved = false
			drag_start = event.position
			drag_center = center
			var view_rect := _view_rect()
			if not view_rect.has_point(event.position):
				_set_center_from_mouse(event.position)
				drag_center = center
			accept_event()
		else:
			dragging = false
			accept_event()
	elif event is InputEventMouseMotion and dragging:
		if event.position.distance_to(drag_start) > 1.0:
			moved = true
		var delta := (
			(event.position - drag_start) / Vector2(maxf(size.x, 1.0), maxf(size.y, 1.0)) / zoom
		)
		center = Vector2(
			clampf(drag_center.x - delta.x, 0.5 / zoom, 1.0 - 0.5 / zoom),
			clampf(drag_center.y - delta.y, 0.5 / zoom, 1.0 - 0.5 / zoom)
		)
		view_changed.emit(center, zoom)
		queue_redraw()
		accept_event()
	elif (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
	):
		var point := Vector2(
			clampf(event.position.x / maxf(size.x, 1.0), 0.0, 1.0),
			clampf(event.position.y / maxf(size.y, 1.0), 0.0, 1.0)
		)
		var factor := 1.18 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.18
		var old_zoom := zoom
		zoom = clampf(zoom * factor, 1.0, 4.0)
		var world_point := center + (point - Vector2(0.5, 0.5)) / old_zoom
		center = world_point - (point - Vector2(0.5, 0.5)) / zoom
		center.x = clampf(center.x, 0.5 / zoom, 1.0 - 0.5 / zoom)
		center.y = clampf(center.y, 0.5 / zoom, 1.0 - 0.5 / zoom)
		view_changed.emit(center, zoom)
		queue_redraw()
		accept_event()


func _set_center_from_mouse(position: Vector2) -> void:
	var normalized := Vector2(position.x / maxf(size.x, 1.0), position.y / maxf(size.y, 1.0))
	center = Vector2(
		clampf(normalized.x, 0.5 / zoom, 1.0 - 0.5 / zoom),
		clampf(normalized.y, 0.5 / zoom, 1.0 - 0.5 / zoom)
	)
	view_changed.emit(center, zoom)
	queue_redraw()


func _view_rect() -> Rect2:
	var extent := Vector2(1.0 / zoom, 1.0 / zoom)
	var top_left := center - extent * 0.5
	var position := top_left * size
	return Rect2(position, extent * size)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0c0f14"), true)
	draw_rect(Rect2(Vector2.ZERO, size), Color("#353c49"), false, 1.0)
	for index in range(1, 3):
		var x := size.x * float(index) / 3.0
		var y := size.y * float(index) / 3.0
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.3, 0.34, 0.42, 0.55), 1.0)
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.3, 0.34, 0.42, 0.55), 1.0)
	var view_rect := _view_rect()
	draw_rect(view_rect, Color(0.72, 0.42, 1.0, 0.16), true)
	draw_rect(view_rect, Color("#e8c9ff"), false, 1.5)
