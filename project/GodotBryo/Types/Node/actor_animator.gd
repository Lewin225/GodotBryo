@tool
class_name ActorAnimator
extends Node

## Loads an actor's locomotion KFs, binds them to its skeleton and plays the
## clip that matches how its controller moves it (the actor node's `motion`). A child of the actor node (esm_actor_node.tscn). NifServer extracts
## and caches the KFs; this only retargets their tracks to this actor's
## Skeleton3D. The AnimationPlayer it drives lives under the actor's Body, the
## root its track paths are relative to.

signal load_completed(clip_count: int)
signal load_failed(reason: String)

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

## Stops loading and removes the AnimationPlayer.
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or _loading or _player == null or not is_instance_valid(_player):
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
## skeleton; null when no track names one of its bones.
func _bind_animation(raw_animation: Animation) -> Animation:
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
		if authored_target == "Bip01" or authored_target == NifNamesScript.escape("Bip01 NonAccum"):
			animation.track_set_enabled(track_index, false)
			continue
		animation.track_set_path(track_index, NodePath("%s:%s" % [skeleton_path, authored_target]))
		tracks += 1
	return animation if tracks > 0 else null
