@tool
extends EditorScript
## Batch-bakes waveform PNGs for every .wav / .ogg / .mp3 found in SOURCE_DIR.
##
## How to use: open this file in the script editor and choose
## [b]File > Run[/b] (Ctrl+Shift+X). Each audio file gets a PNG in OUTPUT_DIR,
## named `<file>_waveform.png`. The filesystem is rescanned afterwards so the
## images show up in the FileSystem dock right away.
##
## Like everything else in this project this runs on the main thread without
## awaiting, so it is safe inside editor scripts.

const SOURCE_DIR := "res://samples"
const OUTPUT_DIR := "res://waveforms"

const IMAGE_OPTIONS := {
	"width": 1600,
	"height": 400,
	"supersample": 2,
	"padding": 12,
	"channel_mode": "mix",
}


func _run() -> void:
	var files := _collect_audio_files(SOURCE_DIR)
	if files.is_empty():
		print("[bake_waveforms] No .wav / .ogg / .mp3 files found in %s" % SOURCE_DIR)
		return

	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)

	# Decode once per file into a resolution pyramid (and cache it), then render the
	# level that suits the export width - so a 1600 px PNG is genuinely detailed.
	var loader := WaveformLoader.new()
	loader.fine_step = 16

	var started := Time.get_ticks_msec()
	var baked := 0

	for path in files:
		var file_started := Time.get_ticks_msec()
		var pyramid := loader.load_pyramid_sync(path)
		if pyramid == null:
			push_warning("[bake_waveforms] %s: %s" % [path, loader.last_error])
			continue
		var data := pyramid.pick(int(IMAGE_OPTIONS["width"]), 1.0)

		var target := OUTPUT_DIR.path_join("%s_waveform.png" % path.get_file().get_basename())
		var error := WaveformRenderer.save_png(data, target, IMAGE_OPTIONS)
		if error != OK:
			push_warning("[bake_waveforms] could not write %s (error %d)" % [target, error])
			continue

		baked += 1
		print("[bake_waveforms] %s -> %s  (%s, %.2fs, %d ms)" % [
			path.get_file(),
			target,
			"stereo" if data.has_stereo() else "mono",
			data.duration,
			Time.get_ticks_msec() - file_started,
		])

	print("[bake_waveforms] done: %d file(s) in %d ms" % [baked, Time.get_ticks_msec() - started])

	if Engine.is_editor_hint():
		var filesystem := EditorInterface.get_resource_filesystem()
		if filesystem != null:
			filesystem.scan()


func _collect_audio_files(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	var dir := DirAccess.open(directory)
	if dir == null:
		return found

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full_path := directory.path_join(entry)
		if dir.current_is_dir():
			found.append_array(_collect_audio_files(full_path))
		elif WaveformBaker.is_supported_file(entry):
			found.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()

	return found
