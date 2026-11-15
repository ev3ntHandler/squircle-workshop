class_name TimelineRuler
extends Control

var waveform: WaveformView
var duration := 0.0
var start_offset := 0.0
var bpm_points: Array[Vector2] = []
var divisions_per_bar := 4


func _ready() -> void:
	custom_minimum_size.y = 24
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0c0f14"), true)
	if waveform == null or duration <= 0.0:
		return
	var visible_span := 1.0 / maxf(waveform.zoom, 1.0)
	var from_time := waveform.view_start * duration
	var to_time := minf((waveform.view_start + visible_span) * duration, duration)
	var step_beats := 4.0 / float(maxi(divisions_per_bar, 1))
	var first_step := floori(_beat_count_at_time(from_time) / step_beats)
	var last_step := ceili(_beat_count_at_time(to_time) / step_beats)
	var last_label_x := -1000.0
	var last_bar_label_x := -1000.0
	var total_steps := maxi(last_step - first_step + 1, 1)
	var bar_stride := maxi(divisions_per_bar, 1)
	var minor_stride := maxi(ceili(float(total_steps) / maxf(size.x / 5.0, 1.0)), 1)
	var first_minor := floori(float(first_step) / float(minor_stride)) * minor_stride
	for step_index in range(first_minor, last_step + 1, minor_stride):
		if posmod(step_index, bar_stride) == 0:
			continue
		var time := _time_at_beat(float(step_index) * step_beats)
		if time < from_time or time > to_time:
			continue
		var x := (time / duration - waveform.view_start) / visible_span * size.x
		draw_line(Vector2(x, 0), Vector2(x, 4), Color(0.78, 0.82, 0.9, 0.35), 1.0)
		if absf(x - last_label_x) >= 48.0:
			var bar_number := floori(float(step_index) / float(bar_stride)) + 1
			var division_index := posmod(step_index, bar_stride) + 1
			draw_string(
				ThemeDB.fallback_font,
				Vector2(x - 24.0, size.y - 5.0),
				"%d.%d" % [bar_number, division_index],
				HORIZONTAL_ALIGNMENT_CENTER,
				48.0,
				10,
				Color("#d5dbe7", 0.62)
			)
			last_label_x = x
	var first_bar := floori(float(first_step) / float(bar_stride))
	var last_bar := ceili(float(last_step) / float(bar_stride))
	var bar_count := maxi(last_bar - first_bar + 1, 1)
	var bar_draw_stride := maxi(ceili(float(bar_count) / maxf(size.x / 12.0, 1.0)), 1)
	var first_drawn_bar := floori(float(first_bar) / float(bar_draw_stride)) * bar_draw_stride
	for bar_index in range(first_drawn_bar, last_bar + 1, bar_draw_stride):
		var step_index := bar_index * bar_stride
		var time := _time_at_beat(float(step_index) * step_beats)
		if time < from_time or time > to_time:
			continue
		var x := (time / duration - waveform.view_start) / visible_span * size.x
		draw_line(Vector2(x, 0), Vector2(x, 7), Color(0.78, 0.82, 0.9, 0.75), 1.0)
		if x - last_bar_label_x >= 36.0:
			draw_string(
				ThemeDB.fallback_font,
				Vector2(x - 24.0, size.y - 5.0),
				str(bar_index + 1),
				HORIZONTAL_ALIGNMENT_CENTER,
				48.0,
				12,
				Color("#d5dbe7", 0.9)
			)
			last_bar_label_x = x


func _beat_count_at_time(time: float) -> float:
	return _raw_beat_count_at_time(time) - _raw_beat_count_at_time(start_offset)


func _raw_beat_count_at_time(time: float) -> float:
	var end_time := clampf(time, 0.0, duration)
	var boundaries: Array[float] = [0.0, end_time]
	for point in bpm_points:
		var point_time := clampf(point.x, 0.0, 1.0) * duration
		if point_time > 0.0 and point_time < end_time:
			boundaries.append(point_time)
	boundaries.sort()
	var beats := 0.0
	for index in range(boundaries.size() - 1):
		var left_time: float = boundaries[index]
		var right_time: float = boundaries[index + 1]
		var average_bpm := (_bpm_at_time(left_time) + _bpm_at_time(right_time)) * 0.5
		beats += average_bpm * (right_time - left_time) / 60.0
	return beats


func _bpm_at_time(time: float) -> float:
	if bpm_points.is_empty():
		return 128.0
	var ratio := clampf(time / maxf(duration, 0.001), 0.0, 1.0)
	var points := bpm_points.duplicate()
	points.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
	if ratio <= points[0].x:
		return maxf(points[0].y, 1.0)
	for index in range(points.size() - 1):
		var left: Vector2 = points[index]
		var right: Vector2 = points[index + 1]
		if ratio <= right.x:
			var width := maxf(right.x - left.x, 0.000001)
			return maxf(lerpf(left.y, right.y, (ratio - left.x) / width), 1.0)
	return maxf(points[-1].y, 1.0)


func _time_at_beat(target_beats: float) -> float:
	var absolute_target := target_beats + _raw_beat_count_at_time(start_offset)
	if absolute_target <= 0.0:
		return 0.0
	var low := 0.0
	var high := duration
	for _iteration in range(24):
		var midpoint := (low + high) * 0.5
		if _raw_beat_count_at_time(midpoint) < absolute_target:
			low = midpoint
		else:
			high = midpoint
	return (low + high) * 0.5
