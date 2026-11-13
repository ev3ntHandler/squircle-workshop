@tool
class_name WaveformView
extends Control
## A [Control] that displays a waveform, with a playhead, horizontal zoom, panning
## and a bass-reactive glow at the playhead.
##
## [b]Zooming[/b] (time axis only, the vertical scale is fixed):
## [br]• mouse wheel = zoom in/out around the cursor
## [br]• Shift + wheel = pan left/right
## [br]• middle or right mouse drag = pan
## [br]• left click / drag = seek (emits [signal seek_requested])
## [br]• [method reset_view] / [code]zoom = 1.0[/code] = back to the whole track
##
## [b]Resolution[/b]: the image is always rendered at the exact pixel width of the
## control and only the visible time window is stretched across it, so zooming does
## not magnify pixels - it reveals detail. That detail comes from the
## [member pyramid], which holds the track decoded at several resolutions: the view
## picks the level with at least one slot per pixel column, so there is no
## re-decoding, no re-rendering lag and no visible switch between "draft" and "full"
## quality while you zoom or while the song plays.
##
## [codeblock]
## var loader := WaveformLoader.new()
## %WaveformView.pyramid = await loader.load_pyramid("res://music/song.ogg")
## %WaveformView.view_changed.connect(func(start, zoom): print(start, zoom))
## %WaveformView.seek_requested.connect(func(ratio): player.seek(ratio * duration))
## [/codeblock]
##
## [b]Playhead pulse[/b]: set [member pulse] (0..1) from a bass/kick level and the
## gradient at the playhead flares up. See [method set_pulse] and
## [member pulse_width].

## Emitted when the user clicks or drags inside the view. [param ratio] is 0..1 of
## the whole track (not of the visible window).
signal seek_requested(ratio: float)
## Emitted whenever the visible window or the zoom level changed.
signal view_changed(start_ratio: float, zoom: float)
## Emitted after the internal texture was rebuilt (e.g. after a resize or zoom).
signal texture_rebuilt

@export_group("Look")
## Top color of the waveform bars.
@export var wave_color_top: Color = Color(0.42, 0.78, 1.0)
## Bottom color of the waveform bars.
@export var wave_color_bottom: Color = Color(0.20, 0.42, 0.95)
## Draw the brighter RMS core inside the bars.
@export var draw_rms: bool = true
## Color and opacity of the RMS core.
@export var rms_color: Color = Color(0.85, 0.96, 1.0, 0.85)
## Background color at the top of the control.
@export var background: Color = Color(0.05, 0.055, 0.07)
## Background color at the bottom of the control.
@export var background_bottom: Color = Color(0.09, 0.10, 0.13)
## Vertical margin in pixels, so loud peaks do not touch the edges.
@export var padding: int = 6
## Space between bars in pixels (0 draws a solid block).
@export var bar_gap: int = 0
## Which channel(s) to draw.
@export_enum("mix", "stereo", "left", "right") var channel_mode: String = "mix":
	set(value):
		channel_mode = value
		_mark_dirty()
## Playhead color.
@export var playhead_color: Color = Color(1.0, 1.0, 1.0, 0.9)
## Tint drawn behind the already played part of the waveform.
@export var played_tint: Color = Color(1.0, 1.0, 1.0, 0.06)
## Anti-aliasing for the internal render: 1 = fastest, 2 = smoother (2x cost).
@export_range(1, 4, 1) var render_supersample: int = 1:
	set(value):
		render_supersample = clampi(value, 1, 4)
		_mark_dirty()
## Blur radius in columns. Softens the envelope into a smooth, drawn-looking wave
## (0 = off, 1..8 = progressively softer).
@export_range(0, 16, 1) var smoothing: int = 0:
	set(value):
		smoothing = maxi(value, 0)
		_mark_dirty()

@export_group("Playback")
## Keep the playhead on screen while the song plays.
@export var follow_playhead: bool = true:
	set(value):
		follow_playhead = value
		queue_redraw()
## `"page"` jumps the window forward in blocks (cheapest, classic DAW behaviour),
## `"center"` keeps the playhead in the middle and scrolls continuously.
@export_enum("page", "center") var follow_style: String = "page"
## Where the playhead lands after a page flip, as a fraction of the window width.
@export_range(0.0, 0.5, 0.01) var follow_lead: float = 0.12
## How much extra width is baked into the texture while `"center"` following, as a
## fraction of the view width (0.5 = half a screen of waveform waiting off to the
## right). The texture then only slides sideways while the playhead advances, so a
## smooth scroll costs no rendering - and, just as important, the bars are not
## re-binned into different columns every frame, which is what makes a continuously
## scrolling waveform shimmer. Higher = fewer re-bakes, more memory.
@export_range(0.0, 2.0, 0.05) var follow_overscan: float = 0.5

@export_group("Playhead pulse")
## Draw the gradient pulse at the playhead.
@export var pulse_enabled: bool = true:
	set(value):
		pulse_enabled = value
		queue_redraw()
## Width of the gradient in pixels.
@export_range(8.0, 1200.0, 1.0) var pulse_width: float = 180.0:
	set(value):
		pulse_width = maxf(value, 8.0)
		queue_redraw()
## Color of the gradient. White reads best on a dark waveform; the gradient fades
## from this color (at the playhead) to fully transparent.
@export var pulse_color: Color = Color(1.0, 1.0, 1.0, 0.9):
	set(value):
		pulse_color = value
		_build_pulse_textures()
		queue_redraw()
## Fade towards the left (behind the playhead) instead of towards the right.
@export var pulse_flip: bool = false:
	set(value):
		pulse_flip = value
		queue_redraw()
## Opacity of the pulse at [code]pulse == 1.0[/code].
@export_range(0.0, 1.0, 0.01) var pulse_max_opacity: float = 0.9
## How fast [member pulse] falls back to zero on its own, per second.
## 0 = the level is only set from outside (recommended, see [method set_pulse]).
@export_range(0.0, 40.0, 0.5) var pulse_decay: float = 0.0

@export_group("Performance")
## How much quality to trade for speed while the view is being zoomed/panned.
## [br]• `"auto"` - draws a cheap flat preview immediately and the full gradient
## render [member quality_delay] seconds after the last interaction (recommended),
## [br]• `"full"` - always the full quality render; smoothest picture, one full
## render per wheel notch (this is the setting that feels sluggish on slow machines),
## [br]• `"fast"` - always the flat, single-rect-per-bar look (cheapest by far).
@export_enum("auto", "full", "fast") var preview_quality: String = "auto":
	set(value):
		preview_quality = value
		if value != "auto":
			_draft = false
		_mark_dirty()
## How long after the last zoom/pan the full quality render replaces the preview.
@export_range(0.0, 1.0, 0.01) var quality_delay: float = 0.18
## Vertical scale of the waveform: 1 = normal, 0.5 = half as tall, 2 = twice as
## tall (clipped at the lane edges). Independent of zoom, so it never sneaks in as
## a side effect of zooming.
@export_range(0.1, 4.0, 0.01) var amplitude_scale: float = 1.0:
	set(value):
		amplitude_scale = maxf(value, 0.05)
		_mark_dirty()
## Let the user drag the bottom edge of the control to change its height.
@export var vertical_resize_enabled: bool = true

@export_group("Zoom")
## Upper limit for [member zoom]. The effective limit is one audio frame per pixel
## column, capped by the resolution of [member pyramid].
@export_range(1.0, 4096.0, 1.0) var max_zoom: float = 512.0
## Multiplier applied per mouse wheel notch.
@export_range(1.01, 4.0, 0.01) var zoom_step: float = 1.25
## What the mouse wheel keeps in place while zooming: the position under the
## cursor, the playhead, or the centre of the view.
@export_enum("cursor", "playhead", "center") var zoom_anchor: String = "cursor"

## The multi-resolution waveform to draw. This is what you normally assign.
var pyramid: WaveformPyramid = null:
	set = _set_pyramid
## A single envelope, used when no [member pyramid] is assigned (small previews,
## one-off renders, backwards compatibility).
var data: WaveformData = null:
	set = _set_data
## Playhead position as 0..1 of the whole track, or a negative value to hide it.
var playback_ratio: float = -1.0:
	set = _set_playback_ratio
## Zoom factor: 1.0 = whole track, 10.0 = one tenth of the track across the view.
var zoom: float = 1.0:
	set = _set_zoom
## Left edge of the visible window, as 0..1 of the whole track.
var view_start: float = 0.0:
	set = _set_view_start
## Pulse level, 0..1. Drives the opacity of the gradient at the playhead.
var pulse: float = 0.0:
	set = _set_pulse

var _texture: ImageTexture = null
var _pulse_texture: ImageTexture = null
var _pulse_texture_flipped: ImageTexture = null
var _dirty := true
var _dragging := false
var _panning := false
var _hover_ratio := -1.0
var _effective_step := 0
# True while the cheap preview is on screen instead of the full gradient render.
var _draft := false
var _quality_cooldown := 0.0
var _resizing := false
# While true, several window changes are applied before a single rebuild.
var _batching := false
# While true the window change is only a horizontal slide of the existing texture.
var _sliding := false
# Geometry of the texture currently on the GPU (see _rebuild / _update_scroll_shift).
var _render_start := 0.0        # track ratio at the left edge of the texture
var _render_span := 1.0         # track ratio the texture covers (view + overscan)
var _render_visible := 1.0      # track ratio the control itself covers
var _render_view_size := Vector2.ZERO  # control size the texture was baked for
var _shift_px := 0              # whole-pixel slide of the texture to the left

## Height of the drag area at the bottom edge that resizes the control.
const RESIZE_GRIP := 10.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if not resized.is_connected(_on_resized):
		resized.connect(_on_resized)
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(240, 120)
	# the pulse gradient is drawn past the playhead, keep it inside the control
	clip_contents = true
	_build_pulse_textures()
	if not _dirty:
		set_process(false)


func _process(delta: float) -> void:
	if pulse_decay > 0.0 and pulse > 0.0:
		pulse = maxf(pulse - pulse_decay * delta, 0.0)

	# upgrade the preview to the full quality render once the user stops moving
	if _quality_cooldown > 0.0:
		_quality_cooldown -= delta
		if _quality_cooldown <= 0.0 and _draft:
			_draft = false
			_dirty = true

	if _dirty:
		_rebuild()
		return
	if _quality_cooldown > 0.0:
		# a fuller render is still scheduled - keep _process alive for it
		return
	if pulse_decay <= 0.0 or pulse <= 0.0:
		set_process(false)


func _draw() -> void:
	if _texture != null:
		# The texture is baked a little wider than the control while the playhead is
		# followed in `"center"` mode; scrolling is then just a whole-pixel blit
		# offset. `fit` is 1:1 unless the control was resized since the last bake.
		var fit := Vector2.ONE
		if _render_view_size.x > 0.5 and _render_view_size.y > 0.5:
			fit = Vector2(size.x / _render_view_size.x, size.y / _render_view_size.y)
		var tex_size := Vector2(_texture.get_width(), _texture.get_height()) * fit
		var offset := Vector2(-float(_shift_px) * fit.x, 0.0)
		draw_texture_rect(_texture, Rect2(offset, tex_size), false)
	else:
		draw_rect(Rect2(Vector2.ZERO, size), background)
		var font := ThemeDB.fallback_font
		if font != null:
			draw_string(font, Vector2(12, size.y * 0.5 + 5), "No waveform data",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.35))

	var visible := _visible_fraction()
	var view_range := get_view_range()

	if playback_ratio >= 0.0:
		var local := (playback_ratio - view_range.x) / visible
		if local >= 0.0 and local <= 1.0:
			var x := local * size.x
			if played_tint.a > 0.0:
				draw_rect(Rect2(0, 0, x, size.y), played_tint)
			_draw_pulse(x)
			var head_width := 2.0 + pulse * 2.0
			draw_rect(Rect2(x - head_width * 0.5, 0, head_width, size.y), playhead_color)

	# vertical resize handle: three dots at the bottom edge, subtle until hovered
	if vertical_resize_enabled:
		var grip_color := Color(1, 1, 1, 0.22 if _is_on_grip(get_local_mouse_position()) else 0.10)
		var grip_y := size.y - 4.0
		var grip_w := 26.0
		var grip_x := size.x * 0.5 - grip_w * 0.5
		draw_rect(Rect2(grip_x, grip_y, grip_w, 2.0), grip_color)

	if _hover_ratio >= 0.0 and not _dragging and not _panning:
		var local_hover := (_hover_ratio - view_range.x) / visible
		if local_hover >= 0.0 and local_hover <= 1.0:
			draw_rect(Rect2(local_hover * size.x - 0.5, 0, 1.0, size.y), Color(1, 1, 1, 0.18))


## Draws the gradient at the playhead. The texture is a single image built once
## (opaque at the playhead, transparent at the far end); [member pulse] only scales
## its opacity, so a kick makes it flare without any per-frame image work.
func _draw_pulse(play_x: float) -> void:
	if not pulse_enabled or pulse <= 0.002:
		return
	var texture := _pulse_texture_flipped if pulse_flip else _pulse_texture
	if texture == null:
		return
	var opacity := clampf(pulse * pulse_max_opacity, 0.0, 1.0)
	var left := play_x - pulse_width if pulse_flip else play_x
	draw_texture_rect(texture, Rect2(left, 0.0, pulse_width, size.y), false,
			Color(1.0, 1.0, 1.0, opacity))


func _build_pulse_textures() -> void:
	var steps := 256
	var image := Image.create(steps, 1, false, Image.FORMAT_RGBA8)
	for x in steps:
		var t := float(x) / float(steps - 1)
		# smooth falloff so the glow does not end in a hard edge
		var alpha := pow(1.0 - t, 1.7)
		image.set_pixel(x, 0, Color(pulse_color.r, pulse_color.g, pulse_color.b, alpha))
	var flipped := Image.create_from_data(steps, 1, false, Image.FORMAT_RGBA8, image.get_data())
	flipped.flip_x()
	_pulse_texture = ImageTexture.create_from_image(image)
	_pulse_texture_flipped = ImageTexture.create_from_image(flipped)


# --- input ----------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_LEFT:
				if button.pressed:
					if _is_on_grip(button.position):
						_resizing = true
					else:
						_dragging = true
						_seek_to(button.position.x)
				else:
					_dragging = false
					if _resizing:
						# re-render now that the height the user wants is fixed
						_resizing = false
						_mark_dirty()
				queue_redraw()
				accept_event()
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_panning = button.pressed
				accept_event()
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					if button.shift_pressed:
						scroll_by(-0.2 * _visible_fraction())
					else:
						zoom_at(zoom_step, _zoom_anchor_at(button.position.x))
					accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					if button.shift_pressed:
						scroll_by(0.2 * _visible_fraction())
					else:
						zoom_at(1.0 / zoom_step, _zoom_anchor_at(button.position.x))
					accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _resizing:
			custom_minimum_size.y = clampf(custom_minimum_size.y + motion.relative.y, 60.0, 1200.0)
			if size_flags_vertical == Control.SIZE_EXPAND_FILL:
				size_flags_vertical = Control.SIZE_FILL
			update_minimum_size()
			accept_event()
		elif _panning:
			if size.x > 0.0:
				scroll_by(-motion.relative.x / size.x * _visible_fraction())
		elif _dragging:
			_seek_to(motion.position.x)
		else:
			_hover_ratio = _ratio_at(motion.position.x)
			mouse_default_cursor_shape = Control.CURSOR_VSIZE if _is_on_grip(motion.position) \
					else Control.CURSOR_ARROW
			queue_redraw()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_EXIT:
			_hover_ratio = -1.0
			_dragging = false
			_panning = false
			_resizing = false
			mouse_default_cursor_shape = Control.CURSOR_ARROW
			queue_redraw()


# --- public API -----------------------------------------------------------

## Forces the texture to be rebuilt on the next frame.
func queue_rebuild() -> void:
	_mark_dirty()


## The texture currently on screen (null before the first render).
func get_texture() -> ImageTexture:
	return _texture


## Visible window as 0..1 ratios of the whole track: `Vector2(start, end)`.
func get_view_range() -> Vector2:
	var start := clampf(view_start, 0.0, 1.0)
	return Vector2(start, minf(start + _visible_fraction(), 1.0))


## Fraction of the whole track that is currently visible (0..1].
func get_visible_fraction() -> float:
	return _visible_fraction()


## Highest zoom allowed: one envelope slot per pixel column of the finest level.
func get_max_zoom() -> float:
	var limit := maxf(max_zoom, 1.0)
	var columns := maxi(int(size.x), 1)
	if pyramid != null and pyramid.get_level_count() > 0:
		return minf(limit, pyramid.get_max_zoom(columns))
	if data != null and data.get_slot_count() > 0:
		return minf(limit, maxf(float(data.get_slot_count()) / float(columns), 1.0))
	return limit


## Zooms in ([param factor] > 1) or out (< 1) keeping [param anchor_ratio] fixed.
func zoom_at(factor: float, anchor_ratio: float = 0.5) -> void:
	if factor <= 0.0:
		return
	var anchor := clampf(anchor_ratio, 0.0, 1.0)
	var anchor_time := view_start + anchor * _visible_fraction()
	var target := clampf(zoom * factor, 1.0, get_max_zoom())
	if is_equal_approx(target, zoom):
		return
	# zoom and the window position change together: rebuild once, not twice
	_batching = true
	zoom = target
	view_start = anchor_time - anchor * _visible_fraction()
	_batching = false
	_commit_view_change()


## Zooms in ([param factor] > 1) or out (< 1) around the centre of the view.
func zoom_by(factor: float) -> void:
	zoom_at(factor, 0.5)


## Pans by [param delta_ratio] of the whole track (positive = later in the track).
func scroll_by(delta_ratio: float) -> void:
	view_start = view_start + delta_ratio


## Sets the visible window directly. [param new_zoom] <= 0 keeps the zoom level.
func set_view(start_ratio: float, new_zoom: float = -1.0) -> void:
	_batching = true
	if new_zoom > 0.0:
		zoom = clampf(new_zoom, 1.0, get_max_zoom())
	view_start = start_ratio
	_batching = false
	_commit_view_change()


## Shows the whole track again.
func reset_view() -> void:
	_batching = true
	zoom = 1.0
	view_start = 0.0
	_batching = false
	_commit_view_change()


## Audio frames per envelope slot currently on screen - smaller means more detail.
func get_effective_step_size() -> int:
	if _effective_step > 0:
		return _effective_step
	var level := _current_level()
	return level.step_size if level != null else 0


## The [WaveformData] level the view is drawing right now (useful for debug output).
func get_current_level() -> WaveformData:
	return _current_level()


## Sets the pulse level (0..1) - feed it a smoothed bass / kick level.
##
## [codeblock]
## view.set_pulse(bass_energy)
## # or push several sources into it:
## view.set_pulse(maxf(view.pulse, kick_energy))
## [/codeblock]
func set_pulse(energy: float) -> void:
	pulse = energy


## Peak amplitude of the audio under the playhead (0..1). Returns 0 without data.
## Cheap enough to call every frame if you need a level without a bus analyser.
func get_amplitude_at_playhead() -> float:
	var level := _current_level()
	if level == null or playback_ratio < 0.0:
		return 0.0
	return level.get_amplitude_at_time(playback_ratio * level.duration + level.window_start)


## Returns exactly what the view is drawing right now, so you can export it:
## [code]{"data": WaveformData, "view_start": float, "view_end": float, "step": int}[/code].
## Feed all of it into [method WaveformRenderer.save_png] to get a PNG that matches
## the screen:
## [codeblock]
## var source := view.get_render_source()
## WaveformRenderer.save_png(source["data"], "user://export.png", {
##     "width": 1600, "height": 420,
##     "view_start": source["view_start"], "view_end": source["view_end"],
## })
## [/codeblock]
func get_render_source() -> Dictionary:
	var level := _current_level()
	var view_range := get_view_range()
	return {
		"data": level,
		"view_start": view_range.x,
		"view_end": view_range.y,
		"step": level.step_size if level != null else 0,
	}


## Render options matching the view's look (the view adds `view_start`/`view_end`
## and `peak` itself).
func get_render_options() -> Dictionary:
	return {
		"width": maxi(int(size.x), 1),
		"height": maxi(int(size.y), 1),
		"columns": 0,
		"supersample": clampi(render_supersample, 1, 4),
		"padding": padding,
		"bar_gap": bar_gap,
		"background": background,
		"background_bottom": background_bottom,
		"wave_color_top": wave_color_top,
		"wave_color_bottom": wave_color_bottom,
		"draw_rms": draw_rms,
		"rms_color": rms_color,
		"channel_mode": channel_mode,
		"stereo_gap": 4,
		"center_line_color": Color(1, 1, 1, 0.0),
		"smoothing": smoothing,
		"gain": amplitude_scale,
	}


# --- internals ------------------------------------------------------------

func _set_pyramid(value: WaveformPyramid) -> void:
	pyramid = value
	var limit := get_max_zoom()
	if zoom > limit:
		zoom = limit
	_mark_dirty()


func _set_data(value: WaveformData) -> void:
	data = value
	_mark_dirty()


func _set_playback_ratio(value: float) -> void:
	if is_equal_approx(value, playback_ratio):
		return
	playback_ratio = value
	_follow_playhead()
	queue_redraw()


func _set_zoom(value: float) -> void:
	var clamped := clampf(value, 1.0, get_max_zoom())
	if is_equal_approx(clamped, zoom):
		return
	zoom = clamped
	var limit := maxf(1.0 - _visible_fraction(), 0.0)
	if view_start > limit:
		view_start = limit          # the setter clamps and re-renders
	else:
		_commit_view_change()


func _set_view_start(value: float) -> void:
	var limit := maxf(1.0 - _visible_fraction(), 0.0)
	var clamped := clampf(value, 0.0, limit)
	if is_equal_approx(clamped, view_start):
		return
	view_start = clamped
	_commit_view_change()


func _set_pulse(value: float) -> void:
	var clamped := clampf(value, 0.0, 1.0)
	if is_equal_approx(clamped, pulse):
		return
	pulse = clamped
	if pulse_decay > 0.0:
		set_process(true)
	queue_redraw()


## Moves the visible window so the playhead stays on screen. `"page"` only jumps
## when the playhead is about to leave the window (one re-render per page);
## `"center"` keeps it pinned in the middle and slides the already baked texture,
## so a continuously scrolling waveform costs nothing per frame.
func _follow_playhead() -> void:
	if not follow_playhead or playback_ratio < 0.0:
		return
	var visible := _visible_fraction()
	if visible >= 0.999:
		return
	if follow_style == "center":
		var target := clampf(playback_ratio - visible * 0.5, 0.0,
				maxf(1.0 - visible, 0.0))
		# The texture is only blitted at whole pixel offsets, so a sub-pixel move
		# would not change a single pixel: skip it instead of re-rendering.
		var pixel := visible / maxf(size.x, 1.0)
		if absf(target - view_start) < pixel * 0.5:
			return
		# The audio position reported by the player wobbles by a millisecond or two,
		# which at a tight zoom is several pixels of shake - never scroll backwards
		# for less than that (a real seek moves much further).
		if target < view_start and view_start - target < pixel * 2.0:
			return
		_sliding = true
		view_start = target          # silent: slides the texture, no rebuild
		_sliding = false
		return
	var lead := clampf(follow_lead, 0.0, 0.5)
	if playback_ratio > view_start + visible * 0.94 or playback_ratio < view_start:
		view_start = clampf(playback_ratio - visible * lead, 0.0, maxf(1.0 - visible, 0.0))


## Slides the baked texture so [member view_start] is on screen, re-baking it only
## once the view runs off the overscanned strip. Called from the `view_start`
## setter while [member _sliding] is on, and never from a plain window change.
func _update_scroll_shift() -> void:
	if _texture == null or _render_span <= 0.0 or _render_view_size.x <= 0.5:
		_rebake_quietly()
		return
	var tex_width := float(_texture.get_width())
	if tex_width < 2.0:
		_rebake_quietly()
		return
	var shift := int(roundf((view_start - _render_start) / _render_span * tex_width))
	var view_px := int(roundf(tex_width * _render_visible / _render_span))
	if shift < 0 or shift + view_px > int(tex_width):
		# ran off the right (or back off the left) edge of the strip: bake a new one
		_rebake_quietly()
		return
	if shift == _shift_px:
		return
	_shift_px = shift
	_arm_follow_preview()
	queue_redraw()
	view_changed.emit(view_start, zoom)


## Re-bakes the texture at the current window. The old texture keeps being drawn
## (at its last valid offset) until the new one is ready, so a refill never leaves
## a blank or misaligned frame behind.
func _rebake_quietly() -> void:
	_arm_follow_preview()
	_mark_dirty()


## `"auto"` keeps the cheap flat preview on screen for as long as the view keeps
## scrolling - a full gradient render every second would hitch the scroll, and the
## full render arrives on its own a moment after the movement stops.
func _arm_follow_preview() -> void:
	if preview_quality != "auto":
		return
	_draft = true
	_quality_cooldown = maxf(quality_delay, 0.05)
	set_process(true)


## True when the next bake should include overscan for centered scrolling.
func _overscan_active() -> bool:
	return follow_playhead and follow_style == "center" and follow_overscan > 0.01 \
			and _visible_fraction() < 0.999 and playback_ratio >= 0.0


## Snaps [param start] down to a whole envelope slot. Re-baked strips then start on
## the same slot grid as the previous ones, so the columns are binned identically
## and a refill does not make the bars jump.
func _snap_to_slot(level: WaveformData, start: float) -> float:
	var slots := level.get_slot_count()
	if slots <= 0:
		return start
	return floorf(clampf(start, 0.0, 1.0) * float(slots)) / float(slots)


func _visible_fraction() -> float:
	return 1.0 / maxf(zoom, 1.0)


## Ratio inside the view that should stay under the mouse wheel while zooming.
func _zoom_anchor_at(x: float) -> float:
	match zoom_anchor:
		"playhead":
			if playback_ratio >= 0.0:
				var local := (playback_ratio - view_start) / _visible_fraction()
				if local >= 0.0 and local <= 1.0:
					return local
			return 0.5
		"center":
			return 0.5
		_:
			return _ratio_at(x)


## True when a point is inside the drag handle at the bottom edge.
func _is_on_grip(point: Vector2) -> bool:
	return vertical_resize_enabled and point.y >= size.y - RESIZE_GRIP


func _commit_view_change() -> void:
	if _sliding:
		# centered follow: the texture already covers this window, so the change is
		# a sideways blit and must never schedule a rebuild
		_update_scroll_shift()
		return
	_dirty = true
	if _batching:
		return
	if preview_quality != "full":
		# cheap preview now, full render after the interaction settles
		_draft = true
		_quality_cooldown = maxf(quality_delay, 0.0)
	set_process(true)
	queue_redraw()
	view_changed.emit(view_start, zoom)


func _mark_dirty() -> void:
	_dirty = true
	set_process(true)


func _on_resized() -> void:
	var clamped := minf(zoom, get_max_zoom())
	if not is_equal_approx(clamped, zoom):
		zoom = clamped
	if _resizing:
		# While the height is being dragged the existing texture is simply
		# stretched; re-rendering the whole image per mouse motion would stutter.
		queue_redraw()
		return
	_mark_dirty()


func _ratio_at(x: float) -> float:
	if size.x <= 0.0:
		return 0.0
	return clampf(view_start + (x / size.x) * _visible_fraction(), 0.0, 1.0)


func _seek_to(x: float) -> void:
	seek_requested.emit(_ratio_at(x))


## The level that should be drawn at the current zoom: the coarsest one that still
## gives a few slots per pixel column (see [method WaveformPyramid.pick]).
func _current_level() -> WaveformData:
	if pyramid != null and pyramid.get_level_count() > 0:
		return pyramid.pick(maxi(int(size.x), 1), _visible_fraction())
	return data


func _peak_reference() -> float:
	if pyramid != null and pyramid.get_level_count() > 0:
		return pyramid.get_peak()
	return data.get_peak() if data != null else 0.0


func _rebuild() -> void:
	_dirty = false
	var level := _current_level()
	if level == null or level.get_slot_count() == 0 or size.x < 2.0 or size.y < 2.0:
		_texture = null
		_effective_step = level.step_size if level != null else 0
		queue_redraw()
		texture_rebuilt.emit()
		return

	var view_range := get_view_range()
	var visible := _visible_fraction()
	var start := view_range.x
	var span := view_range.y - view_range.x
	if _overscan_active():
		# bake a strip wider than the view so centered follow can scroll by blitting
		start = _snap_to_slot(level, start)
		span = minf((view_range.y - view_range.x) * (1.0 + clampf(follow_overscan, 0.1, 2.0)),
				1.0 - start)
		span = maxf(span, minf(visible, 1.0 - start))
	var options := get_render_options()
	options["view_start"] = start
	options["view_end"] = start + span
	if visible > 0.0:
		# keep one texture pixel per screen pixel even though the strip is wider
		options["width"] = maxi(int(roundf(span / visible * size.x)), 1)
	# One normalisation reference for every level, so changing zoom never changes
	# the vertical scale.
	var reference := _peak_reference()
	if reference > 0.0:
		options["peak"] = reference
	if _draft or preview_quality == "fast":
		# Cheap preview: one flat colour, no RMS core, no supersampling. This is
		# the difference between a smooth wheel zoom and a slideshow.
		var mid: Color = wave_color_top.lerp(wave_color_bottom, 0.5)
		options["wave_color_top"] = mid
		options["wave_color_bottom"] = mid
		options["draw_rms"] = false
		options["supersample"] = 1

	var image := WaveformRenderer.render(level, options)
	_render_start = start
	_render_span = span
	_render_visible = visible
	_render_view_size = size
	_shift_px = 0
	if image.is_empty():
		_texture = null
	elif _texture != null and _texture.get_width() == image.get_width() \
			and _texture.get_height() == image.get_height():
		# same size as last frame: reuse the GPU texture instead of re-creating it
		_texture.update(image)
	else:
		_texture = ImageTexture.create_from_image(image)
	# Where the requested window sits inside the freshly baked strip.
	if not image.is_empty() and span > 0.0:
		_shift_px = maxi(int(roundf((view_start - start) / span * float(image.get_width()))), 0)
	_effective_step = level.step_size
	queue_redraw()
	texture_rebuilt.emit()
