extends Node

## For each KF on the command line (path under meshes\): every track's bone and
## type whose bone name contains a word from LEG_WORDS, with its key count,
## first and last value; and whether the bone exists in skeleton.nif.

const LEG_WORDS := ["Thigh", "Calf", "Foot", "Toe", "Pelvis", "NonAccum"]

var _done := {}
var _bones := {}

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var result: Dictionary = ArchiveServer.read("meshes/characters/_male/skeleton.nif")
	var source := NifSource.new()
	if result["found"] and source.load(PackedByteArray(result["data"])):
		for node: Dictionary in source.get_nodes():
			_bones[String(node.get("name", ""))] = true
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
	print("%s: %d tracks, %.2f s" % [path.get_file(), animation.get_track_count(), animation.length])
	for track in animation.get_track_count():
		var bone := String(animation.track_get_path(track))
		var wanted := false
		for word in LEG_WORDS:
			if bone.contains(word):
				wanted = true
		if not wanted:
			continue
		var type: String = ["value", "position", "rotation", "scale", "blend shape", "method", "bezier", "audio", "animation"][animation.track_get_type(track)]
		var keys := animation.track_get_key_count(track)
		var first = animation.track_get_key_value(track, 0)
		var last = animation.track_get_key_value(track, keys - 1)
		if first is Quaternion:
			first = (first.get_euler() * 180.0 / PI).round()
			last = (last.get_euler() * 180.0 / PI).round()
		print("    %s %s: %d keys %s -> %s%s" % [bone, type, keys, first, last, "" if _bones.has(bone.replace("_20", " ")) or _bones.has(bone) else "  (no such bone in skeleton.nif)"])
