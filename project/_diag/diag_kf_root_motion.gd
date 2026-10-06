extends Node

## For each KF on the command line (path under meshes\): its sequences'
## lengths, loop modes, and where Bip01, Bip01 NonAccum and Bip01 Pelvis start
## and end (position and rotation tracks), to see how far a clip carries and
## turns the actor.

const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")
const BONES := ["Bip01", "Bip01 NonAccum", "Bip01 Pelvis"]

var _done := {}

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	for path in OS.get_cmdline_user_args():
		NifServer.request_kf(path, self, _on_library.bind(path))
	while _done.size() < OS.get_cmdline_user_args().size():
		await get_tree().process_frame
	get_tree().quit()

func _on_library(library: AnimationLibrary, path: String) -> void:
	_done[path] = true
	if library == null:
		print("%s: not loaded" % path)
		return
	for name in library.get_animation_list():
		var animation := library.get_animation(name)
		print("%s [%s] length %.2f s, loop %d" % [path.get_file(), name, animation.length, animation.loop_mode])
		for bone in BONES:
			var track := animation.find_track(NodePath(NifNamesScript.escape(bone)), Animation.TYPE_POSITION_3D)
			if track == -1:
				track = animation.find_track(NodePath(bone), Animation.TYPE_POSITION_3D)
			if track == -1:
				print("    %s: no position track" % bone)
				continue
			var keys := animation.track_get_key_count(track)
			var first: Vector3 = animation.track_get_key_value(track, 0)
			var last: Vector3 = animation.track_get_key_value(track, keys - 1)
			print("    %s: %d keys, %s -> %s (moves %.3f m)" % [bone, keys, first, last, first.distance_to(last)])
		for bone in BONES:
			var rotation_track := animation.find_track(NodePath(NifNamesScript.escape(bone)), Animation.TYPE_ROTATION_3D)
			if rotation_track == -1:
				rotation_track = animation.find_track(NodePath(bone), Animation.TYPE_ROTATION_3D)
			if rotation_track == -1:
				continue
			var count := animation.track_get_key_count(rotation_track)
			var start: Quaternion = animation.track_get_key_value(rotation_track, 0)
			var end: Quaternion = animation.track_get_key_value(rotation_track, count - 1)
			print("    %s rotation: euler degrees %s -> %s" % [bone, (start.get_euler() * 180.0 / PI).round(), (end.get_euler() * 180.0 / PI).round()])
