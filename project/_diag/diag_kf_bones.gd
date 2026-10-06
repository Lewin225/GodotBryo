extends Node

## For each KF on the command line (path under meshes\): every track's target
## and type, and for position tracks the first and last value; to see what a
## clip drives.

var _done := {}

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var paths := OS.get_cmdline_user_args()
	for path in paths:
		NifServer.request_kf(path, self, _on_library.bind(path))
	while _done.size() < paths.size():
		await get_tree().process_frame
	get_tree().quit()

func _on_library(library: AnimationLibrary, path: String) -> void:
	_done[path] = true
	if library == null:
		print("%s: not loaded" % path)
		return
	var animation := library.get_animation(library.get_animation_list()[0])
	print("%s: %.2f s, loop %d, %d tracks" % [path.get_file(), animation.length, animation.loop_mode, animation.get_track_count()])
	for track in animation.get_track_count():
		var type: String = ["value", "position", "rotation", "scale", "blend shape", "method", "bezier", "audio", "animation"][animation.track_get_type(track)]
		var line := "    %s %s" % [animation.track_get_path(track), type]
		if type == "position":
			var keys := animation.track_get_key_count(track)
			line += " %s -> %s" % [animation.track_get_key_value(track, 0), animation.track_get_key_value(track, keys - 1)]
		print(line)
