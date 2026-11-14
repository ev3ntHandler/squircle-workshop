extends HSlider


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			value = clampf(float(get_meta("workshop_default_value", value)), min_value, max_value)
			accept_event()
			return
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			accept_event()
			return
	super._gui_input(event)
