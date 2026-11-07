class_name KfClipSync
extends Node
## Makes `follower` play what a source KfAnimator is asked to play
## (Plans/Actors/first_person.md, Sync mode), in the same slot with the same
## fade and speed, following the source's clock; on the source's clip_stopped
## it stops that slot. Which clip it plays for a start is `mode`'s:
##   SAME_CLIP: the start's own Animation, as the source was given it.
##   REMAPPED: the KF at the start's path remapped by `path_remap`, requested
##     from NifServer; when that KF is missing, the start's own Animation if
##     it keys a bone the follower's skeleton has and the source's lacks (a
##     clip only the follower can play, as VCG01's wake-up keys Camera1st),
##     or whatever it keys with `filter_fallback` off.
## A start with no clip to play, or whose clip keys none of the follower's
## bones, leaves the follower's slot empty.

enum Mode {
	SAME_CLIP,
	REMAPPED,
}

## The KfAnimator that plays the source's clips.
@export var follower: KfAnimator
@export var mode := Mode.REMAPPED
## REMAPPED: path prefixes (canonical NifServer paths), from to replacement; the
## first pair, in order, whose prefix a path starts with remaps it, and a path
## no pair matches is requested as it is. The default maps third-person KFs to
## their first-person files: 471 of the 2,256 `_male` KFs have a `_1stperson`
## KF at the same relative path; the standing idle and the two turns sit in
## `_1stperson`'s root rather than its `locomotion` folder (also for the hurt
## variants, which have no first-person file of their own).
@export var path_remap: Dictionary = {
	"characters/_male/locomotion/mtidle.kf": "characters/_1stperson/mtidle.kf",
	"characters/_male/locomotion/mtturnleft.kf": "characters/_1stperson/mtturnleft.kf",
	"characters/_male/locomotion/mtturnright.kf": "characters/_1stperson/mtturnright.kf",
	"characters/_male/locomotion/hurt/mtidle.kf": "characters/_1stperson/mtidle.kf",
	"characters/_male/locomotion/hurt/mtturnleft.kf": "characters/_1stperson/mtturnleft.kf",
	"characters/_male/locomotion/hurt/mtturnright.kf": "characters/_1stperson/mtturnright.kf",
	"characters/_male/": "characters/_1stperson/",
}
## REMAPPED: with no remapped KF, the start's own Animation plays only when it
## keys a bone of the follower's that the source lacks; off, it always plays
## (so the follower shows every clip the source plays, third-person poses
## included, where no remapped KF exists).
@export var filter_fallback := true
## Whether the follower's clips play their Bip01 and Bip01 NonAccum tracks,
## whatever the source's clips do.
@export var keep_root := false
## Prints each start and stop this node handles: the source's path, what the
## follower plays for it (or that its slot is left empty) and why.
@export var debug_log := false

var _source: KfAnimator
## Per slot, a counter raised by each start and stop, so a KF delivered after
## a newer start or stop is dropped.
var _slot_generations := {}


## Follows `source` (null stops following). The follower drops what it plays
## and starts the source's current starts at once, with no fade.
func set_source(source: KfAnimator) -> void:
	if _source != null and is_instance_valid(_source):
		_source.clip_started.disconnect(_on_clip_started)
		_source.clip_stopped.disconnect(_on_clip_stopped)
	_source = source
	_slot_generations.clear()
	if follower == null:
		return
	follower.stop_all()
	if source == null:
		follower.sync_source = NodePath()
		return
	follower.sync_source = follower.get_path_to(source)
	# Processed after the source, so following clips read this frame's time.
	follower.process_priority = source.process_priority + 1
	source.clip_started.connect(_on_clip_started)
	source.clip_stopped.connect(_on_clip_stopped)
	for slot in source.get_started_slots():
		var start := source.get_start(slot)
		_on_clip_started(slot, start["path"], start["animation"], start["serial"], 0.0, start["keep_root"], start["speed"])


func get_source() -> KfAnimator:
	return _source


## `path` with the first matching `path_remap` prefix replaced.
func remap_path(path: String) -> String:
	var canonical := NifServer.canonical(path)
	for from: String in path_remap:
		if canonical.begins_with(from):
			return String(path_remap[from]) + canonical.trim_prefix(from)
	return canonical


func _next_generation(slot: int) -> int:
	var generation := int(_slot_generations.get(slot, 0)) + 1
	_slot_generations[slot] = generation
	return generation


func _on_clip_started(slot: int, path: String, animation: Animation, serial: int, fade_seconds: float, _keep_root: bool, speed: float) -> void:
	var generation := _next_generation(slot)
	if follower == null:
		return
	var fallback: Animation = animation if _may_fall_back(animation) else null
	if mode == Mode.SAME_CLIP:
		_play(slot, animation, path, serial, fade_seconds, speed)
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	if nif_server == null or path.is_empty():
		_play(slot, fallback, path, serial, fade_seconds, speed)
		return
	var remapped := remap_path(path)
	_log("slot %d start %s: requesting %s (fallback %s)" % [slot, path, remapped, "the source's clip" if fallback != null else "none"])
	nif_server.request_kf(remapped, self, _on_kf_delivered.bind(slot, generation, remapped, path, fallback, serial, fade_seconds, speed))


## Whether `animation` may play on the follower when no remapped KF exists.
func _may_fall_back(animation: Animation) -> bool:
	if animation == null:
		return false
	if not filter_fallback:
		return true
	return _keys_follower_only_bone(animation)


## Whether `animation` has a transform track on a bone the follower's skeleton
## has and the source's lacks.
func _keys_follower_only_bone(animation: Animation) -> bool:
	var follower_skeleton := _skeleton_of(follower)
	if follower_skeleton == null:
		return false
	var source_skeleton := _skeleton_of(_source)
	for track in animation.get_track_count():
		var type := animation.track_get_type(track)
		if type != Animation.TYPE_POSITION_3D and type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_SCALE_3D:
			continue
		var bone_name := String(animation.track_get_path(track))
		if follower_skeleton.find_bone(bone_name) == -1:
			continue
		if source_skeleton == null or source_skeleton.find_bone(bone_name) == -1:
			return true
	return false


static func _skeleton_of(animator: KfAnimator) -> Skeleton3D:
	if animator == null or not is_instance_valid(animator) or animator.skeleton_path.is_empty():
		return null
	return animator.get_node_or_null(animator.skeleton_path) as Skeleton3D


func _on_clip_stopped(slot: int, fade_seconds: float) -> void:
	_next_generation(slot)
	_log("slot %d stop" % slot)
	_stop_follower(slot, fade_seconds)


func _on_kf_delivered(library: AnimationLibrary, slot: int, generation: int, remapped: String, path: String, fallback: Animation, serial: int, fade_seconds: float, speed: float) -> void:
	if generation != int(_slot_generations.get(slot, 0)) or follower == null:
		_log("slot %d %s delivered after a newer start or stop: dropped" % [slot, remapped])
		return
	if library == null:
		_log("slot %d %s missing; %s" % [slot, remapped, "playing the source's clip" if fallback != null else "no clip to fall back on"])
	if library != null and not library.get_animation_list().is_empty():
		_play(slot, library.get_animation(library.get_animation_list()[0]), remapped, serial, fade_seconds, speed)
		return
	_play(slot, fallback, path, serial, fade_seconds, speed)


## Plays `animation` on the follower for the source's start `serial`, or
## empties the slot when it is null or keys none of the follower's bones.
func _play(slot: int, animation: Animation, path: String, serial: int, fade_seconds: float, speed: float) -> void:
	if animation == null:
		_log("slot %d %s: nothing to play, slot empty" % [slot, path])
		_stop_follower(slot, fade_seconds)
		return
	if follower.play(slot, animation, fade_seconds, keep_root, speed, path, serial) == 0:
		_log("slot %d %s keys none of the follower's bones, slot empty" % [slot, path])
		_stop_follower(slot, fade_seconds)
		return
	_log("slot %d playing %s (%.2f s, %d tracks)" % [slot, path, animation.length, animation.get_track_count()])


func _log(message: String) -> void:
	if debug_log:
		print("[KfClipSync %s %.2f s] %s" % [get_path(), Time.get_ticks_msec() / 1000.0, message])


func _stop_follower(slot: int, fade_seconds: float) -> void:
	if follower != null:
		follower.stop(slot, fade_seconds)
