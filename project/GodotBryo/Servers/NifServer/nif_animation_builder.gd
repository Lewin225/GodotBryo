@tool
extends RefCounted
class_name NifAnimationBuilder

## Builds standalone KF data into an unbound AnimationLibrary.  A KF is a NIF
## whose sequences address an authored, composed runtime rig rather than a
## tree owned by the file itself, so this builder never guesses a skeleton,
## weapon, or animobject target.

const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")


## One library per file: 4,981 shipped KFs have one sequence, but 33 contain
## 2-5 and cannot be represented honestly by one Animation resource.
##
## Track paths are bare, escaped authored target names. A later composed-rig
## binder owns translating them to Skeleton3D bones or attached scene nodes.
static func build_library(src: NifSource) -> AnimationLibrary:
	if src == null:
		return null
	var sequences: Array = src.get_sequences()
	if sequences.is_empty():
		return null
	var library := AnimationLibrary.new()
	for sequence in sequences:
		var sequence_dict := sequence as Dictionary
		var animation := _build_sequence(sequence_dict)
		var name := NifNamesScript.escape(String(sequence_dict.get("name", "")))
		if name.is_empty():
			name = "Sequence%d" % int(sequence_dict.get("block_index", 0))
		var unique_name := name
		var collision := 0
		while library.has_animation(unique_name):
			collision += 1
			unique_name = "%s__%d" % [name, collision]
		library.add_animation(unique_name, animation)
	return library


static func _build_sequence(sequence: Dictionary) -> Animation:
	var animation := Animation.new()
	var start := float(sequence.get("start_time", 0.0))
	var stop := float(sequence.get("stop_time", start))
	animation.length = maxf(stop - start, 0.001)
	match int(sequence.get("cycle_type", 2)):
		0: animation.loop_mode = Animation.LOOP_LINEAR
		1: animation.loop_mode = Animation.LOOP_PINGPONG
		_: animation.loop_mode = Animation.LOOP_NONE

	var unhandled: PackedStringArray = []
	for controlled in sequence.get("controlled_blocks", []):
		var block := controlled as Dictionary
		var interpolator: Dictionary = block.get("interpolator", {})
		var target := String(block.get("node_name", ""))
		if not bool(interpolator.get("present", false)):
			continue
		if target.is_empty():
			unhandled.append("<unnamed>:%s" % String(interpolator.get("kind", "")))
			continue
		if String(interpolator.get("kind", "")) != "transform":
			# Property/controller semantics are intentionally not inferred here.
			# The raw source remains available through NifSource for their future
			# binding policy; this library is only NifServer's supported transform
			# representation.
			unhandled.append(target + ":" + String(interpolator.get("kind", "")))
			continue
		_add_transform_tracks(animation, NifNamesScript.escape(target), interpolator, start)

	animation.set_meta("nif_sequence_name", String(sequence.get("name", "")))
	animation.set_meta("nif_accum_root", String(sequence.get("accum_root_name", "")))
	animation.set_meta("nif_start_time", start)
	animation.set_meta("nif_text_keys", sequence.get("text_keys", []))
	if not unhandled.is_empty():
		animation.set_meta("nif_unhandled_controller_targets", unhandled)
	return animation


## Keys are already converted to Godot coordinates by NifSource. Times are
## rebased because Godot animation resources begin at zero while a sequence
## records its own source start time as metadata.
static func _add_transform_tracks(animation: Animation, target: String,
		interpolator: Dictionary, start: float) -> int:
	var added := 0
	var resampled := bool(interpolator.get("resampled", false))
	var position_keys: Array = interpolator.get("translation_keys", [])
	if not position_keys.is_empty():
		var track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(track, NodePath(target))
		animation.track_set_interpolation_type(track, _track_interpolation(position_keys, resampled))
		for key in position_keys:
			animation.position_track_insert_key(track, maxf(float(key["time"]) - start, 0.0),
				Vector3(key["value"]))
		added += 1
	var rotation_keys: Array = interpolator.get("rotation_keys", [])
	if not rotation_keys.is_empty():
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath(target))
		animation.track_set_interpolation_type(track, _track_interpolation(rotation_keys, resampled))
		for key in rotation_keys:
			animation.rotation_track_insert_key(track, maxf(float(key["time"]) - start, 0.0),
				(key["value"] as Quaternion).normalized())
		added += 1
	var scale_keys: Array = interpolator.get("scale_keys", [])
	if not scale_keys.is_empty():
		var track := animation.add_track(Animation.TYPE_SCALE_3D)
		animation.track_set_path(track, NodePath(target))
		animation.track_set_interpolation_type(track, _track_interpolation(scale_keys, resampled))
		for key in scale_keys:
			var value := float(key["value"])
			animation.scale_track_insert_key(track, maxf(float(key["time"]) - start, 0.0),
				Vector3(value, value, value))
		added += 1
	return added


static func _track_interpolation(keys: Array, resampled: bool) -> int:
	if resampled:
		return Animation.INTERPOLATION_LINEAR
	var eased := 0
	for key in keys:
		match String(key.get("interp", "")):
			"quadratic", "tbc": eased += 1
	return Animation.INTERPOLATION_CUBIC if eased * 2 > keys.size() else Animation.INTERPOLATION_LINEAR
