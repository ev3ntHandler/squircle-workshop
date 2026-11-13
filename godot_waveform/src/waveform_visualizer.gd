@tool
class_name WaveformVisualizer
extends ColorRect
## Real-time, audio-reactive waveform widget built on the "waveforms" shader from
## [url=https://godotshaders.com/shader/waveforms]godotshaders.com[/url] (CC0).
##
## The shader animates itself from [code]TIME[/code]; the only thing a game has to
## do is feed [member energy] (0 = silence, 1 = full) which is mapped onto the
## shader's [code]progress[/code] uniform, so the wave grows with the music and
## shrinks back when it stops.
##
## [codeblock]
## # in the scene: add a WaveformVisualizer (a ColorRect) anywhere in a CanvasLayer
## %Visualizer.energy = smoothed_bass_level   # 0..1, every frame
## [/codeblock]
##
## The widget creates its own [ShaderMaterial] from
## [code]res://shaders/waveform_visualizer.gdshader[/code]; the exported properties
## below expose the useful subset of the shader's uniforms.

const SHADER_PATH := "res://shaders/waveform_visualizer.gdshader"

## Colour of the wave.
@export var wave_color: Color = Color(0.42, 0.78, 1.0, 1.0):
	set(value):
		wave_color = value
		_apply()
## How many vertical lines build the wave.
@export_range(8, 256, 1) var lines: int = 64:
	set(value):
		lines = maxi(value, 8)
		_apply()
## Lower values create gaps between the lines, higher make the wave more solid.
@export_range(0.0, 1.0, 0.01) var intensity: float = 0.75:
	set(value):
		intensity = value
		_apply()
## Lower values give a smoother, slower wave.
@export_range(0.0, 0.5, 0.01) var frequency: float = 0.1:
	set(value):
		frequency = value
		_apply()
## Height of the wave (the shader's `amplitude`).
@export_range(0.0, 1.0, 0.01) var amplitude: float = 1.0:
	set(value):
		amplitude = value
		_apply()
## Wave speed.
@export_range(0.0, 4.0, 0.05) var speed: float = 0.5:
	set(value):
		speed = value
		_apply()
## Erratic, speech-like movement on top of the regular wave.
@export var speech_sim: bool = true:
	set(value):
		speech_sim = value
		_apply()
## Draw the wave as a dot matrix instead of solid lines.
@export var dot_matrix: bool = false:
	set(value):
		dot_matrix = value
		_apply()
## Level shown when nothing is playing (the shader's `progress` at silence).
@export_range(0.0, 1.0, 0.01) var idle_level: float = 0.3:
	set(value):
		idle_level = value
		_apply()

## Loudness 0..1 driving the animation - feed it a smoothed bass/kick level.
var energy: float = 0.0:
	set(value):
		energy = clampf(value, 0.0, 1.0)
		_apply()

var _material: ShaderMaterial = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_material()
	_apply()


## Rebuilds the material and pushes every uniform to the shader.
func refresh() -> void:
	_ensure_material()
	_apply()


func _ensure_material() -> void:
	if _material != null:
		return
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_error("WaveformVisualizer: could not load %s" % SHADER_PATH)
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	material = _material


func _apply() -> void:
	if not is_node_ready():
		return
	_ensure_material()
	if _material == null:
		return
	_material.set_shader_parameter("lines", lines)
	_material.set_shader_parameter("color", wave_color)
	_material.set_shader_parameter("amplitude", amplitude)
	_material.set_shader_parameter("intensity", intensity)
	_material.set_shader_parameter("frequency", frequency)
	_material.set_shader_parameter("speed", speed)
	_material.set_shader_parameter("speech_sim", speech_sim)
	_material.set_shader_parameter("dot_matrix", dot_matrix)
	_material.set_shader_parameter(
			"progress", clampf(idle_level + (1.0 - idle_level) * energy, 0.0, 1.0))
