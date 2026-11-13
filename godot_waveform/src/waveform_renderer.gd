@tool
class_name WaveformRenderer
extends RefCounted
## Renders a [WaveformData] into an [Image] / [ImageTexture] / PNG file.
##
## The look is driven by an options [Dictionary] - see [method default_options]
## for every key, its default and its meaning. Unknown keys are ignored, known
## keys you do not pass keep their default.
##
## [b]Example:[/b]
## [codeblock]
## var baker := WaveformBaker.new()
## var data: WaveformData = await baker.bake_file("res://music/song.ogg")
##
## # 1) texture for use in a TextureRect / Sprite2D / shader
## var texture := WaveformRenderer.render_texture(data, {
##     "width": 1024, "height": 256,
## })
##
## # 2) PNG on disk
## WaveformRenderer.save_png(data, "user://song_waveform.png", {
##     "width": 1920, "height": 480,
##     "channel_mode": "stereo",
##     "wave_color_top": Color("#7ee0ff"),
##     "wave_color_bottom": Color("#2f6bff"),
## })
## [/codeblock]

## Returns a fresh dictionary with every supported option and its default value.
##
## [codeblock]
## {
##     "width": 1200,                  # output image width in pixels
##     "height": 256,                  # output image height in pixels
##     "columns": 0,                   # distinct waveform columns (0 = one per pixel)
##     "supersample": 2,               # render N-times bigger, then downscale (anti-aliasing)
##     "padding": 10,                  # transparent/background margin above+below, in px
##     "bar_gap": 0,                   # space between bars, in px (0 = solid block)
##     "min_bar_height": 1,            # thinnest bar, in px - keeps silence visible
##     "background": Color(0.05, 0.055, 0.07, 1.0),
##     "background_bottom": Color(0.09, 0.10, 0.13, 1.0),
##     "transparent": false,           # ignore both background colors
##     "wave_color_top": Color(0.42, 0.78, 1.0, 1.0),
##     "wave_color_bottom": Color(0.20, 0.42, 0.95, 1.0),
##     "draw_rms": true,               # brighter core inside each bar
##     "rms_color": Color(0.88, 0.97, 1.0, 0.55),
##     "channel_mode": "mix",          # "mix" | "stereo" | "left" | "right"
##     "stereo_gap": 6,                # gap between the L and R lanes, in px
##     "center_line_color": Color(1, 1, 1, 0.08),
##     "normalize": true,              # scale so the loudest peak touches the edges
##     "gain": 1.0,                    # extra multiplier applied after normalisation
##     "view_start": 0.0,              # first visible position, 0..1 of the envelope
##     "view_end": 1.0,                # last visible position, 0..1 of the envelope
##     "peak": 0.0,                    # normalisation reference; 0 = this data's own peak
##     "smoothing": 0,                 # column smoothing radius (0 = off, 2..8 = soft)
## }
## [/codeblock]
##
## [b]Styling:[/b] `smoothing` runs a two-pass box blur over the reduced columns, which
## turns a spiky min/max envelope into a soft, drawn-looking waveform.
##
## [b]Zooming:[/b] `view_start` / `view_end` select the slice of the envelope that is
## stretched across the full image width, so `0.25 .. 0.30` draws a 20x zoomed
## detail view at full horizontal resolution instead of a blurred crop of the
## whole-track image.
static func default_options() -> Dictionary:
	return {
		"width": 1200,
		"height": 256,
		"columns": 0,
		"supersample": 2,
		"padding": 10,
		"bar_gap": 0,
		"min_bar_height": 1,
		"background": Color(0.05, 0.055, 0.07, 1.0),
		"background_bottom": Color(0.09, 0.10, 0.13, 1.0),
		"transparent": false,
		"wave_color_top": Color(0.42, 0.78, 1.0, 1.0),
		"wave_color_bottom": Color(0.20, 0.42, 0.95, 1.0),
		"draw_rms": true,
		"rms_color": Color(0.88, 0.97, 1.0, 0.55),
		"channel_mode": "mix",
		"stereo_gap": 6,
		"center_line_color": Color(1, 1, 1, 0.08),
		"normalize": true,
		"gain": 1.0,
		"view_start": 0.0,
		"view_end": 1.0,
		"peak": 0.0,
		"smoothing": 0,
	}


## Renders [param data] and returns the resulting [Image].
## Returns an empty [Image] when [param data] has no slots.
static func render(data: WaveformData, options: Dictionary = {}) -> Image:
	if data == null or data.get_slot_count() == 0:
		push_error("WaveformRenderer.render(): no waveform data to draw.")
		return Image.new()

	var o := default_options()
	o.merge(options, true)

	var out_width: int = maxi(int(o["width"]), 1)
	var out_height: int = maxi(int(o["height"]), 1)
	var supersample: int = clampi(int(o["supersample"]), 1, 4)

	var width := out_width * supersample
	var height := out_height * supersample

	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	var background_top: Color = o["background"]
	var background_bottom: Color = o["background_bottom"]

	if bool(o["transparent"]):
		image.fill(Color(0.0, 0.0, 0.0, 0.0))
	else:
		_fill_vertical_gradient(image, background_top, background_bottom)

	# ---- geometry -----------------------------------------------------------
	var padding: int = int(round(float(o["padding"]) * supersample))
	var usable_height: int = maxi(height - padding * 2, 1)

	var channel_mode := String(o["channel_mode"])
	var split_stereo := channel_mode == "stereo" and data.has_stereo()

	var lanes: Array[Rect2i] = []
	var channels: Array[int] = []
	if split_stereo:
		var gap: int = int(round(float(o["stereo_gap"]) * supersample))
		var lane_height: int = maxi(int((usable_height - gap) * 0.5), 1)
		lanes.append(Rect2i(0, padding, width, lane_height))
		lanes.append(Rect2i(0, padding + lane_height + gap, width, lane_height))
		channels.append(WaveformData.CHANNEL_LEFT)
		channels.append(WaveformData.CHANNEL_RIGHT)
	else:
		lanes.append(Rect2i(0, padding, width, usable_height))
		match channel_mode:
			"left":
				channels.append(WaveformData.CHANNEL_LEFT)
			"right":
				channels.append(WaveformData.CHANNEL_RIGHT)
			_:
				channels.append(WaveformData.CHANNEL_MIX)

	# ---- visible time window (zoom) -----------------------------------------
	var slots := data.get_slot_count()
	var view_start := clampf(float(o["view_start"]), 0.0, 1.0)
	var view_end := clampf(float(o["view_end"]), 0.0, 1.0)
	if view_end <= view_start:
		view_end = minf(view_start + 0.000001, 1.0)
	var slot_from := clampi(int(floor(view_start * float(slots))), 0, slots - 1)
	var slot_to := clampi(int(ceil(view_end * float(slots))), slot_from + 1, slots)

	# ---- amplitude scale ----------------------------------------------------
	var gain: float = float(o["gain"])
	if bool(o["normalize"]):
		# `peak` lets a caller keep the vertical scale identical across several
		# renders - e.g. a zoomed detail window must be normalised against the
		# peak of the whole track, not of the window, or the waveform appears to
		# grow when you zoom in.
		var peak := float(o["peak"])
		if peak <= 0.0:
			peak = data.get_peak()
		if peak > 0.0005:
			gain *= 1.0 / peak

	# Bar gap is given in output pixels. column_width is derived from it so that
	# every bar keeps at least one solid output pixel.
	var bar_gap_out: int = maxi(int(round(float(o["bar_gap"]))), 0)
	var bar_gap: int = bar_gap_out * supersample

	var columns: int = int(o["columns"])
	if columns <= 0:
		if bar_gap_out > 0:
			columns = maxi(int(float(out_width) / float(bar_gap_out + 1)), 1)
		else:
			columns = out_width
	columns = clampi(columns, 1, width)

	var min_bar_height: int = maxi(int(round(float(o["min_bar_height"]) * supersample)), 1)
	var column_width := float(width) / float(columns)

	var draw_rms := bool(o["draw_rms"])
	var center_line: Color = o["center_line_color"]

	# Smoothing.
	var smoothing: int = maxi(int(o["smoothing"]), 0)

	# ---- draw one set of bars per lane --------------------------------------
	for lane_index in lanes.size():
		var lane: Rect2i = lanes[lane_index]
		var lane_center := float(lane.position.y) + float(lane.size.y) * 0.5
		var half_height := float(lane.size.y) * 0.5

		var cols := data.reduce(columns, channels[lane_index], slot_from, slot_to)
		if smoothing > 0:
			_smooth_columns(cols, smoothing)

		# Per-row colors so the gradient stays smooth even on 1px bars.
		var row_normal := PackedColorArray()
		var row_core := PackedColorArray()
		row_normal.resize(lane.size.y)
		row_core.resize(lane.size.y)
		var top_color: Color = o["wave_color_top"]
		var bottom_color: Color = o["wave_color_bottom"]
		var core_color: Color = o["rms_color"]
		var flat_wave := top_color.is_equal_approx(bottom_color)
		for row in lane.size.y:
			var t := float(row) / float(maxi(lane.size.y - 1, 1))
			var base := top_color.lerp(bottom_color, t)
			row_normal[row] = base
			row_core[row] = base.lerp(Color(core_color.r, core_color.g, core_color.b, 1.0), core_color.a)

		# Dim centre line, drawn first so the bars cover it. Image.fill_rect()
		# overwrites pixels (alpha included), so the line is pre-blended with the
		# background colour of that row instead of being drawn translucent.
		if center_line.a > 0.0 and not bool(o["transparent"]):
			var line_row := clampi(int(lane_center), 0, height - 1)
			var line_t := float(line_row) / float(maxi(height - 1, 1))
			var row_background := background_top.lerp(background_bottom, line_t)
			var line_color := row_background.lerp(
					Color(center_line.r, center_line.g, center_line.b), center_line.a)
			image.fill_rect(Rect2i(0, line_row, width, supersample), line_color)

		# ---- pass 1: per-column geometry --------------------------------
		var xs := PackedInt32Array()
		var xe := PackedInt32Array()
		var yt := PackedInt32Array()
		var yb := PackedInt32Array()
		var ct := PackedInt32Array()
		var cb := PackedInt32Array()
		xs.resize(columns)
		xe.resize(columns)
		yt.resize(columns)
		yb.resize(columns)
		ct.resize(columns)
		cb.resize(columns)

		for column in columns:
			var x_start := int(float(column) * column_width)
			var x_end := int(float(column + 1) * column_width)
			if x_end <= x_start:
				x_end = x_start + 1
			x_start = clampi(x_start, 0, width - 1)
			x_end = clampi(x_end - bar_gap, x_start + 1, width)

			var high := clampf(cols.max_values[column] * gain, -1.0, 1.0)
			var low := clampf(cols.min_values[column] * gain, -1.0, 1.0)
			var y_top := int(round(lane_center - high * half_height))
			var y_bottom := int(round(lane_center - low * half_height))

			if y_bottom - y_top < min_bar_height:
				var middle := int((y_top + y_bottom) * 0.5)
				y_top = middle - int(min_bar_height * 0.5)
				y_bottom = y_top + min_bar_height

			y_top = clampi(y_top, lane.position.y, lane.end.y - 1)
			y_bottom = clampi(y_bottom, lane.position.y, lane.end.y - 1)

			xs[column] = x_start
			xe[column] = x_end
			yt[column] = y_top
			yb[column] = y_bottom

			# RMS core, clipped to the bar (ct > cb means "no core")
			ct[column] = 1
			cb[column] = 0
			if draw_rms:
				var rms := clampf(cols.rms_values[column] * gain, 0.0, 1.0)
				if rms > 0.0:
					var core_top := clampi(int(round(lane_center - rms * half_height)), y_top, y_bottom)
					var core_bottom := clampi(int(round(lane_center + rms * half_height)), y_top, y_bottom)
					if core_bottom >= core_top:
						ct[column] = core_top
						cb[column] = core_bottom

		# ---- pass 2: draw -----------------------------------------------
		if flat_wave:
			# One fill_rect per bar (plus one for its core) - cheapest path.
			var main_color: Color = row_normal[0]
			var core_flat: Color = row_core[0]
			for column in columns:
				image.fill_rect(Rect2i(xs[column], yt[column],
						xe[column] - xs[column], yb[column] - yt[column] + 1), main_color)
				if cb[column] >= ct[column]:
					image.fill_rect(Rect2i(xs[column], ct[column],
							xe[column] - xs[column], cb[column] - ct[column] + 1), core_flat)
		else:
			# Vertical gradient: scan rows and merge touching columns into runs, so
			# the number of fill_rect() calls stays close to the image height
			# instead of columns * pixels.
			_draw_span_rows(image, lane, xs, xe, yt, yb, row_normal)
			if draw_rms:
				_draw_span_rows(image, lane, xs, xe, ct, cb, row_core)

	if supersample > 1:
		image.resize(out_width, out_height, Image.INTERPOLATE_LANCZOS)
	return image


## Renders [param data] and returns an [ImageTexture] you can assign to a
## [TextureRect], [Sprite2D], [TextureButton] or a shader parameter.
static func render_texture(data: WaveformData, options: Dictionary = {}) -> ImageTexture:
	var image := render(data, options)
	if image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


## Renders [param data] and writes it to [param path] as a PNG.
## Accepts `res://`, `user://` and absolute paths. Returns an [enum Error].
static func save_png(data: WaveformData, path: String, options: Dictionary = {}) -> Error:
	var image := render(data, options)
	if image.is_empty():
		return ERR_CANT_CREATE
	var directory := path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	return image.save_png(path)


## One-shot convenience: decode [param audio_path] and write a PNG next to it
## (or to [param png_path]). Blocking - use it from editor tools or batch scripts.
static func bake_and_save(audio_path: String, png_path: String, options: Dictionary = {}) -> Error:
	var baker := WaveformBaker.new()
	baker.use_cache = false
	var data := baker.bake_file_sync(audio_path)
	if data == null:
		push_error("WaveformRenderer.bake_and_save(): %s" % baker.last_error)
		return ERR_CANT_OPEN
	var target := png_path
	if target.is_empty():
		target = audio_path.get_basename() + "_waveform.png"
	return save_png(data, target, options)


## Fills every [param tops]..[param bots] span row by row, merging horizontally
## touching columns into single rects. [param row_colors] holds one colour per row
## of [param lane], which is what produces the vertical gradient.
static func _draw_span_rows(image: Image, lane: Rect2i, xs: PackedInt32Array, xe: PackedInt32Array, tops: PackedInt32Array, bots: PackedInt32Array, row_colors: PackedColorArray) -> void:
	var lane_top := lane.position.y
	var lane_rows := lane.size.y
	var columns := tops.size()
	for row in lane_rows:
		var y := lane_top + row
		var color := row_colors[row]
		var run_start := -1
		var run_end := -1
		for c in columns:
			if tops[c] > y or bots[c] < y:
				if run_start >= 0:
					image.fill_rect(Rect2i(run_start, y, run_end - run_start, 1), color)
					run_start = -1
				continue

			var x0 := xs[c]
			var x1 := xe[c]
			if run_start < 0:
				run_start = x0
				run_end = x1
			elif x0 <= run_end:
				if x1 > run_end:
					run_end = x1
			else:
				image.fill_rect(Rect2i(run_start, y, run_end - run_start, 1), color)
				run_start = x0
				run_end = x1
		if run_start >= 0:
			image.fill_rect(Rect2i(run_start, y, run_end - run_start, 1), color)


## Softens the reduced columns with two box-blur passes (a cheap triangular
## kernel), which turns a spiky min/max envelope into a smooth curve.
static func _smooth_columns(cols: WaveformData.Columns, radius: int) -> void:
	if cols.count < 3 or radius <= 0:
		return
	cols.min_values = _box_blur(_box_blur(cols.min_values, radius), radius)
	cols.max_values = _box_blur(_box_blur(cols.max_values, radius), radius)
	cols.rms_values = _box_blur(_box_blur(cols.rms_values, radius), radius)


static func _box_blur(values: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var count := values.size()
	var out := PackedFloat32Array()
	out.resize(count)
	if count == 0:
		return out
	for i in count:
		var from_index := maxi(i - radius, 0)
		var to_index := mini(i + radius, count - 1)
		var total := 0.0
		for j in range(from_index, to_index + 1):
			total += values[j]
		out[i] = total / float(to_index - from_index + 1)
	return out


static func _fill_vertical_gradient(image: Image, top: Color, bottom: Color) -> void:
	var height := image.get_height()
	var width := image.get_width()
	for y in height:
		var t := float(y) / float(maxi(height - 1, 1))
		image.fill_rect(Rect2i(0, y, width, 1), top.lerp(bottom, t))
