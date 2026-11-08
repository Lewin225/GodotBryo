@tool
class_name ActorAnimator
extends Node

## The actor's animation: loads its locomotion KFs, plays the clip that
## matches how its controller moves it (the actor node's `motion`) and plays
## IDLEs over it. A child of the actor node (esm_actor_node.tscn). NifServer
## extracts and caches the KFs; a KfAnimator child plays them on the actor's
## Skeleton3D, one slot per animation group section, each bone taken by the
## highest controlled block priority among the playing clips
## (Plans/Actors/animation_blending.md).
##
## Locomotion plays in MOVEMENT_SLOT, in place (its Bip01 and Bip01 NonAccum
## tracks not played). `play_idle` plays an IDLE's KF in the slot of its
## animation group section (DATA byte 0, low six bits), its root tracks kept,
## replacing only the idle in that slot: idles in other slots (a dialogue
## gesture over a seated loop) and locomotion keep playing, and each bone goes
## to the highest priority among them. A once-only idle that reaches its end
## reports idle_finished and fades out of its slot; `stop_idle` ends one idle,
## or all. An idle of section 20 (Whole Body), once it plays, ends the idles in
## every other slot (the chair exit ends the seated loop, which would otherwise
## outrank standing when the exit ends). That rule is a tested guess: read from
## the section's name and checked in animation_viewer.tscn, not against
## the original game (Plans/Actors/animation_blending.md, Root bones). The IDLE's loop section is
## its StartLoop / EndLoop keys, played a random count between its Looping min
## and max, forever for LOOP_FOREVER.
##
## Root motion. The KfAnimator runs in ROOT_TRANSFORM: every clip, locomotion
## too, plays its Bip01 and Bip01 NonAccum tracks and is drawn with its root
## taken out (Bip01 at the origin, NonAccum at the stance), and the root's
## change since the clip started is the actor's to take. Each frame the idle
## being measured from moves the actor by its step since the last frame,
## reported as `root_moved` in the actor node's parent's space (the
## controller's); locomotion's is not reported, the controller moving the actor
## while it walks. A clip started from its end reports all of its motion at once
## (an actor restored seated is placed at the furniture marker, and its enter
## carries it into the seat). So the chair enter carries the actor 0.78 m into
## the seat and turns it about 180 degrees, and the exit carries it back off. This reading of the
## KFs' root (Bip01's translation then NonAccum's facing, composed) is a tested
## guess: it plays Doc's chair enter, seated loop and exit correctly in
## animation_viewer.tscn, not checked against the original game
## (Plans/Actors/animation_blending.md, Root bones).
##
## A creature (`load_locomotion` with `creature`) takes its clips from the KFs
## directly in its skeleton folder and in that folder's `locomotion/`, and
## picks each by file name from creature_locomotion_candidates(): creature
## folders have uneven sets (43 skeleton folders in FalloutNV.esm's CREA; 12
## have no mtforward, 23 no mtleft or mtright, several only mtidle).

signal load_completed(clip_count: int)
signal load_failed(reason: String)
## A once-only idle from play_idle reached its end.
signal idle_finished(idle: IdleBase)
## An idle's root motion since the last emit, in the actor node's parent's
## space: the caller moves the actor by it (`transform * motion`). Emitted from
## the actor's process thread group; connect deferred.
signal root_moved(motion: Transform3D)

const ANIMATOR_NODE_NAME := "KfAnimator"
const LOCOMOTION_SUBDIRECTORY := "locomotion/"
const IDLE_CLIP_PATH := "locomotion/mtidle.kf"
## Crossfade between locomotion clips, and between idles in one slot, seconds.
const BLEND_SECONDS := 0.2
## Below this planar speed (m/s) the actor stands: idle or turning in place.
const STANDING_SPEED := 0.1
## Above this turn rate (rad/s) a standing actor plays a turn clip.
const TURNING_RATE := 0.5
const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")
## The bones whose tracks carry root motion.
const ROOT_BONES := ["Bip01", "Bip01 NonAccum"]
## What playing_clip() reports while an idle plays.
const IDLE_CLIP_NAME := "idle__current"
## IDLE DATA loop count meaning Loop Forever (on 85 of 1,597 IDLEs, min and max
## both; Plans/Completed Plans/Actors/stage_f.md).
const LOOP_FOREVER := 255
## The KfAnimator slot locomotion plays in: animation group section 1, Movement.
const MOVEMENT_SLOT := 1
## The slot of a drawn weapon's stance (`<family>aim.kf`) and the slot of its
## equip, attack, reload and jam clips, which follows the weapon's animator.
## `# ASSUMPTION` above every IDLE section (0 to 63, SECTION_MASK) so neither
## meets an idle; no data assigns weapon clips an animation group section.
const WEAPON_STANCE_SLOT := 64
const WEAPON_ACTION_SLOT := 65
## IDLE DATA byte 0's section bits; the upper two are flags.
const SECTION_MASK := 0x3F
## Animation group section 20, Whole Body.
const WHOLE_BODY_SECTION := 20

var _generation := 0
var _loading := false
var _root_path := ""
var _pending_requests := 0
var _requests_being_submitted := false
var _animator: KfAnimator = null
var _skeleton: Skeleton3D = null
## Locomotion clips by clip name (_clip_name()): NifServer's Animations.
var _clips: Dictionary = {}
## Each locomotion clip's KF path (NifServer canonical), by clip name.
var _clip_paths: Dictionary = {}
## The locomotion clip playing in MOVEMENT_SLOT, or "".
var _locomotion_clip := ""
## The drawn weapon's clip family (1hp, 2hr, ...), "" with none drawn.
var _weapon_family := ""
## KF path -> its Animation, for clips loaded on demand (weapon stance and
## actions); a null value is a KF that failed to load.
var _weapon_clips := {}
## The weapon action being followed: [path, serial, source], [] for none.
var _weapon_action: Array = []
## The idle play_idle last started that still plays or loads, or null.
var _idle: IdleBase = null
## Slot -> the IDLE asked for in it, playing or still loading.
var _slot_idles: Dictionary = {}
## Slot -> its IDLE's clip, once it plays.
var _slot_animations: Dictionary = {}
## Slot -> request number; a KF arriving for an older request is dropped.
var _slot_generations: Dictionary = {}
## Slots whose once-only idle has reached its end and holds its last frame
## until the idles still loading arrive.
var _finished_slots: Array[int] = []
## Idles fade in and out over their KF's blend text keys instead of
## BLEND_SECONDS: in, the first `blend:N` key; out, a `blendout:N` key, else the
## same; N read as frames at 30 a second. Off by default: the keys' meaning is
## not known (Plans/Actors/animation_blending.md, Text keys); the test scene
## turns it on to compare.
var fade_from_text_keys := false
## Frames a second the blend keys' N is read in.
const BLEND_KEY_FRAMES_PER_SECOND := 30.0

## Locomotion KFs below each search path's locomotion folder, by that folder:
## the same for every actor sharing the search path.
static var _locomotion_paths: Dictionary = {}
## Whether this actor's clips are a creature's (chosen by file name).
var _creature := false
## Creature clips by KF file name without extension ("mtidle") -> clip name.
var _creature_clips: Dictionary = {}

## Finds every locomotion KF below `search_paths` (the base's animation search
## paths), requests them from NifServer and plays the idle on `skeleton`. The
## KfAnimator exists as soon as this is called, so the actor has a playback
## endpoint while the KFs are still loading. `body` is the actor's assembly
## root; it must be valid while the KFs load.
func load_locomotion(search_paths: PackedStringArray, body: Node3D, skeleton: Skeleton3D, creature := false) -> void:
	cancel()
	if search_paths.is_empty() or body == null or skeleton == null or not is_inside_tree():
		return
	_skeleton = skeleton
	_creature = creature
	_creature_clips.clear()
	_ensure_animator()
	var archive := get_tree().root.get_node_or_null("ArchiveServer")
	if archive == null or not archive.is_ready():
		load_failed.emit("ArchiveServer is unavailable")
		return
	var paths := PackedStringArray()
	for search_path in search_paths:
		var found := _creature_locomotion_kfs(archive, String(search_path)) if creature \
				else _locomotion_kfs(archive, String(search_path) + LOCOMOTION_SUBDIRECTORY)
		for path in found:
			if not paths.has(path):
				paths.append(path)
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
	_finish_if_ready()

## The KFs below `folder`, canonical paths, listed once per folder.
static func _locomotion_kfs(archive: Node, folder: String) -> PackedStringArray:
	if _locomotion_paths.has(folder):
		return _locomotion_paths[folder]
	var paths := PackedStringArray()
	for path in archive.list_files_with_prefix(folder):
		var canonical := String(path).replace("\\", "/").to_lower()
		if canonical.ends_with(".kf"):
			paths.append(canonical)
	_locomotion_paths[folder] = paths
	return paths

## The KFs directly in a creature's skeleton `folder` and in its
## `locomotion/` (not deeper, so not `locomotion/hurt/`, `idleanims/` or
## `specialanims/`), canonical paths, listed once per folder.
static func _creature_locomotion_kfs(archive: Node, folder: String) -> PackedStringArray:
	var key := "creature:" + folder
	if _locomotion_paths.has(key):
		return _locomotion_paths[key]
	var canonical_folder := folder.replace("\\", "/").to_lower()
	var paths := PackedStringArray()
	for path in archive.list_files_with_prefix(folder):
		var canonical := String(path).replace("\\", "/").to_lower()
		if not canonical.ends_with(".kf"):
			continue
		var relative := canonical.trim_prefix(canonical_folder)
		if not relative.contains("/") or (relative.begins_with(LOCOMOTION_SUBDIRECTORY) and relative.count("/") == 1):
			paths.append(canonical)
	_locomotion_paths[key] = paths
	return paths

## Plays `idle`'s KF in its section's slot over locomotion, its root tracks
## kept; emits idle_finished when a once-only clip ends. A null idle, or one
## without a KF, finishes at once. `from_end` starts it at its last frame, for
## an actor already past it (seated when its animations load).
func play_idle(idle: IdleBase, from_end := false) -> void:
	if idle == null or not idle.has_kf() or _animator == null or not is_instance_valid(_animator):
		idle_finished.emit.call_deferred(idle)
		return
	var slot := idle.animation_group_section & SECTION_MASK
	var generation := int(_slot_generations.get(slot, 0)) + 1
	_slot_generations[slot] = generation
	_slot_idles[slot] = idle
	_idle = idle
	var path := NifServer.canonical(idle.model_path)
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	nif_server.request_kf(path, self, _on_idle_library_delivered.bind(slot, generation, idle, from_end, path))

## Ends `idle` (its slot fades out, the others play on), or every idle when
## null. A looping idle ends here too.
func stop_idle(idle: IdleBase = null) -> void:
	for slot: int in _slot_idles.keys():
		if idle == null or _slot_idles[slot] == idle:
			_end_slot(slot, BLEND_SECONDS)

## The fade in for `animation`: BLEND_SECONDS, or with fade_from_text_keys its
## first `blend:N` key's N frames.
func _fade_in(animation: Animation) -> float:
	if not fade_from_text_keys:
		return BLEND_SECONDS
	var frames := _blend_key_frames(animation, "blend")
	return frames / BLEND_KEY_FRAMES_PER_SECOND if frames > 0.0 else BLEND_SECONDS

## The fade out for `animation` with fade_from_text_keys: its `blendout:N`
## key's N frames, else its fade in.
func _fade_out(animation: Animation) -> float:
	var frames := _blend_key_frames(animation, "blendout")
	return frames / BLEND_KEY_FRAMES_PER_SECOND if frames > 0.0 else _fade_in(animation)

## N of `animation`'s first text key named `kind` ("blend: 12" for "blend"),
## or 0 when it has none.
static func _blend_key_frames(animation: Animation, kind: String) -> float:
	for key: Dictionary in animation.get_meta("nif_text_keys", []):
		var value := String(key.get("value", "")).to_lower().replace(" ", "")
		if value.begins_with(kind + ":"):
			return value.trim_prefix(kind + ":").to_float()
	return 0.0

## Drops the idle in `slot`, fading its clip out over `fade` seconds, and drops
## a KF still on its way for it.
func _end_slot(slot: int, fade: float) -> void:
	_slot_generations[slot] = int(_slot_generations.get(slot, 0)) + 1
	_slot_idles.erase(slot)
	_slot_animations.erase(slot)
	_finished_slots.erase(slot)
	if _animator != null and is_instance_valid(_animator):
		var animation := _animator.get_animation(slot)
		_animator.stop(slot, _fade_out(animation) if fade_from_text_keys and animation != null and fade > 0.0 else fade)
	_idle = null
	for remaining: int in _slot_idles:
		_idle = _slot_idles[remaining]

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

## The idle play_idle is playing, or null.
func get_idle() -> IdleBase:
	return _idle

## IDLE_CLIP_NAME while an idle's clip plays, else the locomotion clip's name
## (_clip_name(): its path below the animation root, "/" as "__"), or "".
func playing_clip() -> String:
	if not _slot_animations.is_empty():
		return IDLE_CLIP_NAME
	return _locomotion_clip

## The IDLEs playing or loading, by slot.
func get_idles() -> Dictionary:
	return _slot_idles.duplicate()

## The KfAnimator playing this actor's clips, or null before load_locomotion.
func get_kf_animator() -> KfAnimator:
	return _animator if _animator != null and is_instance_valid(_animator) else null

## The face morph weights the last started idle's KF, else the locomotion
## clip's, sets at its current time, by morph name (NifAnimationBuilder's `nif_face_tracks`);
## empty when that clip animates none.
func face_weights() -> Dictionary:
	var weights := {}
	if _animator == null or not is_instance_valid(_animator):
		return weights
	var slot := MOVEMENT_SLOT
	for idle_slot: int in _slot_animations:
		if _slot_idles.get(idle_slot) == _idle:
			slot = idle_slot
	var animation := _animator.get_animation(slot)
	if animation == null:
		return weights
	var tracks: Dictionary = animation.get_meta("nif_face_tracks", {})
	var time := _animator.get_time(slot)
	for morph_name: String in tracks:
		weights[morph_name] = _sample_face_track(tracks[morph_name], time)
	return weights

## A face track's value at `time`: linear between keys, held before the first
## and after the last.
static func _sample_face_track(pairs: PackedFloat32Array, time: float) -> float:
	@warning_ignore("integer_division")
	var key_count := pairs.size() / 2
	if key_count == 0:
		return 0.0
	if time <= pairs[0]:
		return pairs[1]
	for key in range(1, key_count):
		var key_time := pairs[key * 2]
		if time > key_time:
			continue
		var previous_time := pairs[key * 2 - 2]
		var weight := 0.0
		if key_time > previous_time:
			weight = (time - previous_time) / (key_time - previous_time)
		return lerpf(pairs[key * 2 - 1], pairs[key * 2 + 1], weight)
	return pairs[key_count * 2 - 1]

## Whether the locomotion clips have loaded, so an idle can play.
func is_loaded() -> bool:
	return not _loading and _animator != null and is_instance_valid(_animator)

func _on_idle_library_delivered(raw_library: AnimationLibrary, slot: int, generation: int, idle: IdleBase, from_end: bool, path: String) -> void:
	if generation != int(_slot_generations.get(slot, 0)) or _animator == null or not is_instance_valid(_animator):
		return
	var animation: Animation = null
	if raw_library != null and not raw_library.get_animation_list().is_empty():
		animation = raw_library.get_animation(raw_library.get_animation_list()[0])
	if animation == null or not _keys_a_bone(animation, true):
		push_warning("ActorAnimator: could not play idle %s (%s)" % [idle.editor_id, idle.model_path])
		# Announced all the same, with the clip when it loaded, for a
		# KfClipSync follower that can play it (a clip keying only Camera1st,
		# on the first-person skeleton).
		_animator.announce(slot, path, animation, BLEND_SECONDS, true, 1.0)
		_slot_idles.erase(slot)
		idle_finished.emit(idle)
		_end_finished_slots()
		return
	_animator.play(slot, animation, _fade_in(animation), true, 1.0, path)
	_slot_animations[slot] = animation
	_finished_slots.erase(slot)
	if slot == WHOLE_BODY_SECTION:
		for other: int in _slot_idles.keys():
			if other != slot:
				_end_slot(other, BLEND_SECONDS)
	_end_finished_slots()
	# Written now, not at the KfAnimator's next process, so the clip's pose
	# shows in the frame it starts.
	_animator.update_pose()
	if from_end:
		# A once-only clip reports its end, through _on_clip_finished, on the
		# KfAnimator's next process; its root motion arrives as one step.
		_animator.seek(slot, animation.length)
		return
	_set_loop_section(animation, idle, slot)

## Whether any of `animation`'s tracks names one of the skeleton's bones, the
## root bones counting only with `with_root` (an idle; locomotion does not play
## them).
func _keys_a_bone(animation: Animation, with_root: bool) -> bool:
	var root_names := [NifNamesScript.escape(ROOT_BONES[0]), NifNamesScript.escape(ROOT_BONES[1])]
	for track in animation.get_track_count():
		var path := String(animation.track_get_path(track))
		if not with_root and root_names.has(path):
			continue
		if _skeleton.find_bone(path) != -1:
			return true
	return false

## Sets the idle clip's loop section from its StartLoop / EndLoop text keys
## (NifServer's `nif_text_keys` metadata; 256 of the 258 looping IDLEs' KFs have
## them), played a random count between the IDLE's Looping min and max, at
## least once, forever for LOOP_FOREVER.
func _set_loop_section(animation: Animation, idle: IdleBase, slot: int) -> void:
	var start := float(animation.get_meta("nif_start_time", 0.0))
	var loop_start := -1.0
	var loop_end := -1.0
	for key: Dictionary in animation.get_meta("nif_text_keys", []):
		var value := String(key.get("value", "")).strip_edges().to_lower()
		if value == "startloop":
			loop_start = float(key["time"]) - start
		elif value == "endloop":
			loop_end = float(key["time"]) - start
	if loop_start < 0.0 or loop_end <= loop_start:
		return
	var count := -1
	if idle.loop_maximum < LOOP_FOREVER:
		count = maxi(randi_range(idle.loop_minimum, maxi(idle.loop_minimum, idle.loop_maximum)), 1)
	_animator.set_loop_section(slot, loop_start, loop_end, count)

## A once-only idle reached its end: reports it, then ends it unless a handler
## has already played or stopped something in its slot. While an idle is still
## loading (the seated loop asked for when the enter ends) it holds its last
## frame until that one plays.
func _on_clip_finished(slot: int, animation: Animation) -> void:
	if _slot_animations.get(slot) != animation:
		return
	var idle: IdleBase = _slot_idles[slot]
	idle_finished.emit(idle)
	if _slot_animations.get(slot) != animation:
		return
	if _loading_idle_count() > 0:
		_finished_slots.append(slot)
		return
	stop_idle(idle)

## How many idles are asked for and not yet playing.
func _loading_idle_count() -> int:
	var loading := 0
	for slot: int in _slot_idles:
		if not _slot_animations.has(slot):
			loading += 1
	return loading

## Ends the finished idles held for the ones loading, once none is loading.
func _end_finished_slots() -> void:
	if _loading_idle_count() > 0:
		return
	var finished := _finished_slots.duplicate()
	_finished_slots.clear()
	for slot: int in finished:
		if _slot_idles.has(slot):
			stop_idle(_slot_idles[slot])

## Chooses the locomotion clip; it keeps playing under an idle.
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or _loading or _animator == null or not is_instance_valid(_animator):
		return
	var actor := get_parent() as EsmActorNode
	var clip_name := ""
	if _creature:
		clip_name = _creature_clip(actor.motion if actor != null else null)
	else:
		var female := actor != null and actor.is_female()
		var motion := actor.motion if actor != null else null
		var clip := locomotion_clip(motion, female)
		clip_name = _clip_name(_root_path + clip, 0)
		var family_clip := _clip_name(_root_path + family_locomotion_clip(motion, _weapon_family), 0)
		if not _weapon_family.is_empty() and _clips.has(family_clip):
			clip_name = family_clip
		if not _clips.has(clip_name):
			clip_name = _clip_name(_root_path + IDLE_CLIP_PATH, 0)
	_play_locomotion(clip_name, BLEND_SECONDS)

func _play_locomotion(clip_name: String, fade: float) -> void:
	if clip_name == _locomotion_clip or not _clips.has(clip_name):
		return
	_animator.play(MOVEMENT_SLOT, _clips[clip_name], fade, true, 1.0, _clip_paths.get(clip_name, ""))
	_locomotion_clip = clip_name

## Reports the idles' root motion since the last frame (root_moved): the
## KfAnimator adds it up at each pose write, so a clip that ends or is replaced
## between frames still counts; locomotion's slot is left out.
func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _animator == null or not is_instance_valid(_animator):
		return
	var step := _animator.consume_root_motion()
	if step.is_equal_approx(Transform3D.IDENTITY):
		return
	root_moved.emit(_in_parent_space(step))

## A skeleton-space transform in the actor node's parent's space.
func _in_parent_space(motion: Transform3D) -> Transform3D:
	var actor := get_parent() as Node3D
	var frame := actor.get_parent() as Node3D if actor != null else null
	if frame == null or _skeleton == null or not is_instance_valid(_skeleton):
		return Transform3D.IDENTITY
	var relative := frame.global_basis.inverse() * _skeleton.global_basis
	var axes := relative.orthonormalized()
	var scale := relative.get_scale().x
	return Transform3D(axes * motion.basis * axes.inverse(), axes * motion.origin * scale)

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

## The drawn weapon family's locomotion KF for `motion` (relative to the
## animation root): `locomotion/<family><pace><direction>.kf` (1hpforward,
## 2hrfastleft); "" standing or with no family. The family clips sit in
## `locomotion/` beside the unarmed ones and key the whole body (1hpforward:
## legs at priority 30, spine 31, right arm 35).
static func family_locomotion_clip(motion: ActorMotion, family: String) -> String:
	if family.is_empty() or motion == null or motion.get_planar_speed() < STANDING_SPEED:
		return ""
	var forward: float = -motion.velocity.z
	var right: float = motion.velocity.x
	var direction := ""
	if absf(forward) >= absf(right):
		direction = "forward" if forward > 0.0 else "backward"
	else:
		direction = "right" if right > 0.0 else "left"
	var pace := "fast" if motion.running else ""
	return LOCOMOTION_SUBDIRECTORY + "%s%s%s.kf" % [family, pace, direction]


## A weapon of `family` is drawn ("" for none): locomotion picks the family's
## clips, and its stance (`<family>aim.kf`, the weapon-out idle) plays in
## WEAPON_STANCE_SLOT on the actor's own clock.
func set_weapon_family(family: String) -> void:
	if family == _weapon_family:
		return
	_weapon_family = family
	_locomotion_clip = ""
	if family.is_empty():
		if _animator != null and is_instance_valid(_animator):
			_animator.stop(WEAPON_STANCE_SLOT, BLEND_SECONDS)
		return
	_play_weapon_clip(WEAPON_STANCE_SLOT, WeaponBase.CLIP_FOLDER + family + "aim.kf", 0, null)


## Plays the KF at `path` in WEAPON_ACTION_SLOT following `source`'s clip of
## `serial` in the same slot (the weapon's animator: the clock, and the only
## one emitting the clip's events).
func follow_weapon_action(path: String, serial: int, source: KfAnimator) -> void:
	_weapon_action = [path, serial, source]
	_play_weapon_clip(WEAPON_ACTION_SLOT, path, serial, source)


## Ends the followed weapon action.
func stop_weapon_action(fade: float) -> void:
	_weapon_action = []
	if _animator != null and is_instance_valid(_animator):
		_animator.stop(WEAPON_ACTION_SLOT, fade)


func _play_weapon_clip(slot: int, path: String, serial: int, source: KfAnimator) -> void:
	if _animator == null or not is_instance_valid(_animator):
		return
	var key := NifServer.canonical(path)
	if not _weapon_clips.has(key):
		NifServer.request_kf(key, self, _on_weapon_clip_delivered.bind(slot, key))
		return
	var clip: Animation = _weapon_clips[key]
	if clip == null:
		return
	if source != null and is_instance_valid(source):
		var sources := _animator.slot_sync_sources
		sources[slot] = _animator.get_path_to(source)
		_animator.slot_sync_sources = sources
	_animator.play(slot, clip, BLEND_SECONDS, false, 1.0, key, serial)


func _on_weapon_clip_delivered(library: AnimationLibrary, slot: int, key: String) -> void:
	var clip: Animation = null
	if library != null and not library.get_animation_list().is_empty():
		clip = library.get_animation(library.get_animation_list()[0])
	_weapon_clips[key] = clip
	if slot == WEAPON_STANCE_SLOT and not _weapon_family.is_empty() and key == NifServer.canonical(WeaponBase.CLIP_FOLDER + _weapon_family + "aim.kf"):
		_play_weapon_clip(slot, key, 0, null)
	elif slot == WEAPON_ACTION_SLOT and not _weapon_action.is_empty() and NifServer.canonical(String(_weapon_action[0])) == key:
		_play_weapon_clip(slot, key, int(_weapon_action[1]), _weapon_action[2])


## The KF file names, most fitting first, a creature plays for `motion`: the
## clip for its direction and pace, then the nearest it may lack; a creature
## with none of them idles. mtbackrward is the dog's misspelt backward clip.
static func creature_locomotion_candidates(motion: ActorMotion) -> PackedStringArray:
	if motion == null:
		return PackedStringArray(["mtidle"])
	if motion.get_planar_speed() < STANDING_SPEED:
		if motion.turn_rate > TURNING_RATE:
			return PackedStringArray(["mtturnleft", "mtidle"])
		if motion.turn_rate < -TURNING_RATE:
			return PackedStringArray(["mtturnright", "mtidle"])
		return PackedStringArray(["mtidle"])
	var forward: float = -motion.velocity.z
	var right: float = motion.velocity.x
	var ahead := PackedStringArray(["mtfastforward", "mtforward"]) if motion.running \
			else PackedStringArray(["mtforward", "mtfastforward"])
	var candidates := PackedStringArray()
	if absf(forward) >= absf(right):
		if forward < 0.0:
			candidates.append_array(["mtbackward", "mtbackrward"])
	else:
		candidates.append("mtright" if right > 0.0 else "mtleft")
	candidates.append_array(ahead)
	candidates.append("mtidle")
	return candidates

## The first of creature_locomotion_candidates(motion) this creature has.
func _creature_clip(motion: ActorMotion) -> String:
	for candidate in creature_locomotion_candidates(motion):
		if _creature_clips.has(candidate):
			return _creature_clips[candidate]
	return ""

func cancel() -> void:
	_generation += 1
	_idle = null
	_slot_idles.clear()
	_slot_animations.clear()
	_finished_slots.clear()
	for slot: int in _slot_generations:
		_slot_generations[slot] = int(_slot_generations[slot]) + 1
	_loading = false
	_root_path = ""
	_pending_requests = 0
	_requests_being_submitted = false
	_clips.clear()
	_clip_paths.clear()
	_locomotion_clip = ""
	if _animator != null and is_instance_valid(_animator):
		_animator.queue_free()
	_animator = null
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
		_add_clips(source_path, raw_library)
	if not _requests_being_submitted:
		_finish_if_ready()

func _finish_if_ready() -> void:
	if not _loading or _pending_requests > 0:
		return
	_loading = false
	if _animator == null or not is_instance_valid(_animator):
		load_failed.emit("the KfAnimator was unavailable")
		return
	var idle_clip := _creature_clip(null) if _creature else _clip_name(_root_path + IDLE_CLIP_PATH, 0)
	if _clips.has(idle_clip):
		_play_locomotion(idle_clip, 0.0)
	else:
		push_warning("ActorAnimator: default idle clip was not loaded: " + idle_clip)
	load_completed.emit(_clips.size())

func _ensure_animator() -> KfAnimator:
	if _animator != null and is_instance_valid(_animator):
		return _animator
	var animator := KfAnimator.new()
	animator.name = ANIMATOR_NODE_NAME
	add_child(animator)
	animator.skeleton_path = animator.get_path_to(_skeleton)
	animator.clip_finished.connect(_on_clip_finished)
	animator.root_motion_mode = KfAnimator.ROOT_MOTION_ROOT_TRANSFORM
	animator.root_motion_excluded_slot = MOVEMENT_SLOT
	_animator = animator
	return animator

## Files each sequence of `raw_library` that keys one of the skeleton's bones
## under its clip name.
func _add_clips(source_path: String, raw_library: AnimationLibrary) -> void:
	var sequence_index := 0
	for raw_name in raw_library.get_animation_list():
		var animation := raw_library.get_animation(raw_name)
		if animation != null and _skeleton != null and is_instance_valid(_skeleton) and _keys_a_bone(animation, false):
			var clip_name := _clip_name(source_path, sequence_index)
			while _clips.has(clip_name):
				clip_name += "_"
			_clips[clip_name] = animation
			_clip_paths[clip_name] = NifServer.canonical(source_path)
			var file_name := source_path.get_file().get_basename()
			if _creature and sequence_index == 0 and not _creature_clips.has(file_name):
				_creature_clips[file_name] = clip_name
		sequence_index += 1

func _clip_name(source_path: String, sequence_index: int) -> String:
	var relative := source_path.trim_prefix(_root_path)
	if relative.is_empty():
		relative = source_path.get_file()
	var clip_name := relative.replace("/", "__")
	return clip_name if sequence_index == 0 else "%s__%d" % [clip_name, sequence_index]
