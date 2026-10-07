@tool
class_name ActorAnimator
extends Node

## Loads an actor's locomotion KFs, binds them to its skeleton and plays the
## clip that matches how its controller moves it (the actor node's `motion`). A child of the actor node (esm_actor_node.tscn). NifServer extracts
## and caches the KFs; this only retargets their tracks to this actor's
## Skeleton3D. The AnimationPlayer it drives lives under the actor's Body, the
## root its track paths are relative to.
##
## `play_idle` plays an IDLE's KF instead of locomotion until `stop_idle`.
## Locomotion clips play in place (their Bip01 and Bip01 NonAccum tracks off);
## an idle keeps them, so a furniture idle carries the body from where the
## controller stands (the furniture marker) into the seat and back. An idle
## holds every bone it has no track for where the previous clip left it (the
## seated loop drives no calves, pelvis or root), except Bip01's rotation,
## held at identity: the
## clips are authored with Bip01 as the accumulation root at the actor's origin,
## unrotated (it carries no rotation track; the chair enter's first frame faces
## the way the actor stands only with Bip01 unrotated, not at its 90-degree
## rest; _diag/diag_idle_facing). Locomotion never animates the root bones, so
## `stop_idle` puts them back where they were before the first idle and reports
## how far that turns the torso, for the caller to turn the actor instead
## (standing up from a chair leaves the body facing away from it).

signal load_completed(clip_count: int)
signal load_failed(reason: String)
## A once-only idle from play_idle reached its end.
signal idle_finished(idle: IdleBase)

const PLAYER_NODE_NAME := "LocomotionAnimationPlayer"
const LOCOMOTION_SUBDIRECTORY := "locomotion/"
const IDLE_CLIP_PATH := "locomotion/mtidle.kf"
const CLIPS_PER_FRAME := 4
## Crossfade between locomotion clips, seconds.
const BLEND_SECONDS := 0.2
## Below this planar speed (m/s) the actor stands: idle or turning in place.
const STANDING_SPEED := 0.1
## Above this turn rate (rad/s) a standing actor plays a turn clip.
const TURNING_RATE := 0.5
const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")
## The bones whose tracks carry root motion.
const ROOT_BONES := ["Bip01", "Bip01 NonAccum"]
## The library name an idle clip is added under.
const IDLE_CLIP_NAME := "idle__current"

var _generation := 0
var _loading := false
var _root_path := ""
var _pending_requests := 0
var _requests_being_submitted := false
var _binding_scheduled := false
var _pending_libraries: Array[Dictionary] = []
var _player: AnimationPlayer = null
var _body: Node3D = null
var _skeleton: Skeleton3D = null
## The idle play_idle is playing, or null for locomotion.
var _idle: IdleBase = null
var _idle_generation := 0
## Bone index -> [position, rotation] of each root bone when locomotion last
## handed over to an idle; empty while locomotion plays.
var _locomotion_root_pose: Dictionary = {}

## Finds every locomotion KF below `search_paths` (the base's animation search
## paths), requests them from NifServer, binds each to `skeleton` and plays the
## idle. The AnimationPlayer exists as soon as this is called, so the actor has
## a playback endpoint while the KFs are still loading.
func load_locomotion(search_paths: PackedStringArray, body: Node3D, skeleton: Skeleton3D) -> void:
	cancel()
	if search_paths.is_empty() or body == null or skeleton == null or not is_inside_tree():
		return
	_body = body
	_skeleton = skeleton
	_ensure_player()
	var archive := get_tree().root.get_node_or_null("ArchiveServer")
	if archive == null or not archive.is_ready():
		load_failed.emit("ArchiveServer is unavailable")
		return
	var paths := PackedStringArray()
	for search_path in search_paths:
		for path in archive.list_files_with_prefix(String(search_path) + LOCOMOTION_SUBDIRECTORY):
			var canonical := String(path).replace("\\", "/").to_lower()
			if canonical.ends_with(".kf") and not paths.has(canonical):
				paths.append(canonical)
	paths.sort()
	if paths.is_empty():
		load_failed.emit("no locomotion KFs found below the animation search paths")
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	if nif_server == null:
		load_failed.emit("NifServer autoload is unavailable")
		return
	_generation += 1
	_loading = true
	_root_path = String(search_paths[0]).replace("\\", "/").to_lower()
	var generation := _generation
	_pending_requests = paths.size()
	_requests_being_submitted = true
	for path in paths:
		# The callback is owner-bound, coalesced, worker-built and cached by
		# NifServer. This node must not read or parse raw KF data itself.
		nif_server.request_kf(path, self, _on_kf_library_delivered.bind(generation, path))
	_requests_being_submitted = false
	_schedule_binding()

## Plays `idle`'s KF in place of locomotion, its root tracks kept; emits
## idle_finished when a once-only clip ends. A null idle, or one without a KF,
## finishes at once. `from_end` starts it at its last frame, for an actor
## already past it (seated when its animations load).
func play_idle(idle: IdleBase, from_end := false) -> void:
	_idle_generation += 1
	if _idle == null:
		_remember_locomotion_root_pose()
	_idle = idle
	if idle == null or not idle.has_kf() or _player == null or not is_instance_valid(_player):
		idle_finished.emit.call_deferred(idle)
		return
	var path := idle.model_path.replace("\\", "/").to_lower()
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	nif_server.request_kf(path, self, _on_idle_library_delivered.bind(_idle_generation, idle, from_end))

## Returns to locomotion, with the root bones back where locomotion left them.
## Returns how far that turns the torso about the up axis (radians, Godot
## yaw): turning the actor by it keeps the body facing the way the idle left it.
func stop_idle() -> float:
	_idle_generation += 1
	_idle = null
	var before := _torso_yaw()
	if _player != null and is_instance_valid(_player) and _player.get_animation_library("").has_animation(IDLE_CLIP_NAME):
		_player.stop()
		_player.get_animation_library("").remove_animation(IDLE_CLIP_NAME)
	_restore_locomotion_root_pose()
	var after := _torso_yaw()
	return angle_difference(after, before)

## The yaw of the torso (Bip01 Spine2's z axis) in the skeleton's parent's
## space, radians; 0 without a skeleton.
func _torso_yaw() -> float:
	if _skeleton == null or not is_instance_valid(_skeleton):
		return 0.0
	var bone := _skeleton.find_bone(NifNamesScript.escape("Bip01 Spine2"))
	if bone == -1:
		return 0.0
	var axis := (_skeleton.transform.basis * _skeleton.get_bone_global_pose(bone).basis) * Vector3.BACK
	return atan2(axis.x, axis.z)

func _remember_locomotion_root_pose() -> void:
	_locomotion_root_pose.clear()
	if _skeleton == null or not is_instance_valid(_skeleton):
		return
	for bone_name in ROOT_BONES:
		var bone := _skeleton.find_bone(NifNamesScript.escape(bone_name))
		if bone != -1:
			_locomotion_root_pose[bone] = [_skeleton.get_bone_pose_position(bone), _skeleton.get_bone_pose_rotation(bone)]

func _restore_locomotion_root_pose() -> void:
	if _skeleton == null or not is_instance_valid(_skeleton):
		_locomotion_root_pose.clear()
		return
	for bone: int in _locomotion_root_pose:
		_skeleton.set_bone_pose_position(bone, _locomotion_root_pose[bone][0])
		_skeleton.set_bone_pose_rotation(bone, _locomotion_root_pose[bone][1])
	_locomotion_root_pose.clear()

## The idle play_idle is playing, or null.
func get_idle() -> IdleBase:
	return _idle

## Whether the locomotion clips have loaded, so an idle can play.
func is_loaded() -> bool:
	return not _loading and _player != null and is_instance_valid(_player)

func _on_idle_library_delivered(raw_library: AnimationLibrary, generation: int, idle: IdleBase, from_end: bool) -> void:
	if generation != _idle_generation or _player == null or not is_instance_valid(_player):
		return
	var animation: Animation = null
	if raw_library != null and not raw_library.get_animation_list().is_empty():
		animation = _bind_animation(raw_library.get_animation(raw_library.get_animation_list()[0]), true)
	if animation == null:
		push_warning("ActorAnimator: could not play idle %s (%s)" % [idle.editor_id, idle.model_path])
		idle_finished.emit(idle)
		return
	_hold_missing_tracks(animation)
	var library := _player.get_animation_library("")
	if library.has_animation(IDLE_CLIP_NAME):
		_player.stop()
		library.remove_animation(IDLE_CLIP_NAME)
	library.add_animation(IDLE_CLIP_NAME, animation)
	if not from_end:
		_player.play(IDLE_CLIP_NAME, BLEND_SECONDS)
		return
	_player.play(IDLE_CLIP_NAME)
	_player.seek(animation.length, true)
	if animation.loop_mode == Animation.LOOP_NONE:
		idle_finished.emit.call_deferred(idle)

## For each bone `animation` has no rotation or position track for, a one-key
## track holding the bone where it is now, so an idle that drives only some
## bones plays over the pose the previous clip left (the seated loop has no
## calf or pelvis tracks: without this the knees straighten to rest). Bip01's
## rotation is held at identity instead (the clips' frame). Holding untouched
## bones is how Gamebryo's layered sequences are read here, not verified: it
## approximates a lower sequence still holding them.
func _hold_missing_tracks(animation: Animation) -> void:
	var skeleton_path := _body.get_path_to(_skeleton)
	for bone in _skeleton.get_bone_count():
		var bone_name := _skeleton.get_bone_name(bone)
		var path := NodePath("%s:%s" % [skeleton_path, bone_name])
		if animation.find_track(path, Animation.TYPE_POSITION_3D) == -1:
			var track := animation.add_track(Animation.TYPE_POSITION_3D)
			animation.track_set_path(track, path)
			animation.position_track_insert_key(track, 0.0, _skeleton.get_bone_pose_position(bone))
		if animation.find_track(path, Animation.TYPE_ROTATION_3D) == -1:
			var track := animation.add_track(Animation.TYPE_ROTATION_3D)
			animation.track_set_path(track, path)
			var held := Quaternion.IDENTITY if bone_name == "Bip01" else _skeleton.get_bone_pose_rotation(bone)
			animation.rotation_track_insert_key(track, 0.0, held)

func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name == IDLE_CLIP_NAME and _idle != null:
		idle_finished.emit(_idle)

## Chooses the locomotion clip; an idle from play_idle replaces it.
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or _loading or _player == null or not is_instance_valid(_player):
		return
	if _idle != null:
		return
	var actor := get_parent() as EsmActorNode
	var female := actor != null and actor.is_female()
	var clip := locomotion_clip(actor.motion if actor != null else null, female)
	var clip_name := _clip_name(_root_path + clip, 0)
	if not _player.has_animation(clip_name):
		clip_name = _clip_name(_root_path + IDLE_CLIP_PATH, 0)
	if _player.current_animation != clip_name and _player.has_animation(clip_name):
		_player.play(clip_name, BLEND_SECONDS)

## The unarmed humanoid locomotion KF (relative to the animation root) for
## `motion`: idle, a turn while standing, or the walk or run clip for the
## direction it moves in. Null motion idles. Idle and turns sit in
## `locomotion/`; the unarmed movement clips in `locomotion/male/` and
## `locomotion/female/` (and `child/`, not chosen yet).
static func locomotion_clip(motion: ActorMotion, female: bool) -> String:
	if motion == null:
		return IDLE_CLIP_PATH
	if motion.get_planar_speed() < STANDING_SPEED:
		if motion.turn_rate > TURNING_RATE:
			return LOCOMOTION_SUBDIRECTORY + "mtturnleft.kf"
		if motion.turn_rate < -TURNING_RATE:
			return LOCOMOTION_SUBDIRECTORY + "mtturnright.kf"
		return IDLE_CLIP_PATH
	var forward: float = -motion.velocity.z
	var right: float = motion.velocity.x
	var direction := ""
	if absf(forward) >= absf(right):
		direction = "forward" if forward > 0.0 else "backward"
	else:
		direction = "right" if right > 0.0 else "left"
	var pace := "fast" if motion.running else ""
	var body := "female/" if female else "male/"
	return LOCOMOTION_SUBDIRECTORY + body + "mt%s%s.kf" % [pace, direction]

func cancel() -> void:
	_generation += 1
	_idle_generation += 1
	_idle = null
	_loading = false
	_root_path = ""
	_pending_requests = 0
	_requests_being_submitted = false
	_binding_scheduled = false
	_pending_libraries.clear()
	if _player != null and is_instance_valid(_player):
		_player.queue_free()
	_player = null
	_body = null
	_skeleton = null

func _exit_tree() -> void:
	cancel()

func _on_kf_library_delivered(raw_library: AnimationLibrary, generation: int, source_path: String) -> void:
	if generation != _generation or not _loading:
		return
	_pending_requests = maxi(0, _pending_requests - 1)
	if raw_library == null:
		push_warning("ActorAnimator: NifServer could not load locomotion KF " + source_path)
	else:
		_pending_libraries.append({"path": source_path, "library": raw_library})
	if not _requests_being_submitted:
		_schedule_binding()

func _schedule_binding() -> void:
	if not _loading or _requests_being_submitted or _binding_scheduled:
		return
	if _pending_libraries.is_empty():
		_finish_if_ready()
		return
	_binding_scheduled = true
	call_deferred("_process_pending_libraries")

## NifServer does the expensive authored-key conversion in its worker. Binding
## copies only the resulting resource and changes its track paths for this
## actor's Skeleton3D. A real process-frame yield is deliberate: call_deferred
## alone drains recursive batches inside the same frame.
func _process_pending_libraries() -> void:
	while _loading and not _pending_libraries.is_empty():
		if not is_instance_valid(_body) or not is_instance_valid(_skeleton):
			cancel()
			return
		var library := _ensure_player().get_animation_library("")
		var processed := 0
		while not _pending_libraries.is_empty() and processed < CLIPS_PER_FRAME:
			var entry: Dictionary = _pending_libraries.pop_front()
			var raw_library := entry.get("library") as AnimationLibrary
			if raw_library != null:
				_bind_library(library, String(entry.get("path", "")), raw_library)
			processed += 1
		if not _pending_libraries.is_empty():
			await get_tree().process_frame
	_binding_scheduled = false
	_finish_if_ready()

func _finish_if_ready() -> void:
	if not _loading or _pending_requests > 0 or not _pending_libraries.is_empty():
		return
	_loading = false
	var player := _ensure_player() if is_instance_valid(_body) else null
	var library := player.get_animation_library("") if player != null else null
	if library == null:
		load_failed.emit("locomotion animation player was unavailable")
		return
	var idle_clip := _clip_name(_root_path + IDLE_CLIP_PATH, 0)
	if library.has_animation(idle_clip):
		player.play(idle_clip)
	else:
		push_warning("ActorAnimator: default idle clip was not loaded: " + idle_clip)
	load_completed.emit(library.get_animation_list().size())

func _ensure_player() -> AnimationPlayer:
	if _player != null and is_instance_valid(_player):
		return _player
	var player := AnimationPlayer.new()
	player.name = PLAYER_NODE_NAME
	# Track paths are relative to Body, the assembly root that owns SkeletonModel
	# and equipment.
	player.root_node = NodePath("..")
	player.add_animation_library("", AnimationLibrary.new())
	player.animation_finished.connect(_on_animation_finished)
	_body.add_child(player)
	if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
		player.owner = get_tree().edited_scene_root
	_player = player
	return player

func _bind_library(library: AnimationLibrary, source_path: String, raw_library: AnimationLibrary) -> void:
	var sequence_index := 0
	for raw_name in raw_library.get_animation_list():
		var animation := _bind_animation(raw_library.get_animation(raw_name))
		if animation != null:
			var clip_name := _clip_name(source_path, sequence_index)
			while library.has_animation(clip_name):
				clip_name += "_"
			animation.set_meta("nif_source_path", source_path)
			library.add_animation(clip_name, animation)
		sequence_index += 1

func _clip_name(source_path: String, sequence_index: int) -> String:
	var relative := source_path.trim_prefix(_root_path)
	if relative.is_empty():
		relative = source_path.get_file()
	var clip_name := relative.replace("/", "__")
	return clip_name if sequence_index == 0 else "%s__%d" % [clip_name, sequence_index]

## A copy of `raw_animation` with its tracks retargeted to this actor's
## skeleton; null when no track names one of its bones. Root bone tracks are
## turned off unless `keep_root` (idles).
func _bind_animation(raw_animation: Animation, keep_root := false) -> Animation:
	if raw_animation == null:
		return null
	var animation := raw_animation.duplicate(true) as Animation
	var skeleton_path := _body.get_path_to(_skeleton)
	var tracks := 0
	for track_index in animation.get_track_count():
		var authored_target := String(animation.track_get_path(track_index))
		if _skeleton.find_bone(authored_target) == -1:
			animation.track_set_enabled(track_index, false)
			continue
		# Root motion must later drive the controller, not deform the in-place
		# visual rig. The authored non-accumulation helper has the same role.
		if not keep_root and (authored_target == "Bip01" or authored_target == NifNamesScript.escape("Bip01 NonAccum")):
			animation.track_set_enabled(track_index, false)
			continue
		animation.track_set_path(track_index, NodePath("%s:%s" % [skeleton_path, authored_target]))
		tracks += 1
	return animation if tracks > 0 else null
