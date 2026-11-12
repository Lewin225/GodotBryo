extends Node
class_name NifObjectAnimator

## Plays a NIF object's animation: its animation group, and its free
## controllers. NifTreeBuilder adds one to a tree whose AnimationPlayer
## library has a sequence or an auto-play free-controller clip (has_work()), as
## a child of the tree's root; every copy of a cached tree runs its own. The clips stay in the
## AnimationPlayer library (exported with the scene); this plays them on a
## KfAnimator, so clips of differing lengths run at once.
##
## GROUP_SLOT plays the object's animation group: its default group when the
## tree is ready (default_group(): Idle, else SpecialIdle), replaced by
## play_group() (PlayGroup, through the reference's anim_group). Census of the
## records using a manager NIF: the unscripted ones that loop are Idle or
## SpecialIdle (55 STATs Idle, 48 STATs SpecialIdle, 222 TERMs SpecialIdle, 21
## MSTTs Idle); Open/Close, Forward/Backward and Left/Right are states set by
## activation or script. A clamped group holds its last frame and does not
## return to the default group. `# ASSUMPTION`: the original does not return
## to it either.
##
## Each auto-play free-controller clip (`nif_autoplay`, NifTreeBuilder) plays
## in its own slot from FIRST_FREE_SLOT up: at its `nif_frequency` as speed,
## sought to its `nif_phase`, looping or clamped as its cycle type says. A
## clamped one leaves its slot when it reaches its end: its last values stay
## on the nodes, and it no longer writes them, so another animator that drives
## the same node afterwards wins. A weapon's own setup controllers
## (minigun.nif's ##MinigunGun visibility, -0.03 to 0 s) would otherwise
## rewrite the part over the holster KF that hides it. `# ASSUMPTION`: a later
## driver wins in Gamebryo too.

## The name NifTreeBuilder gives this node.
const NODE_NAME := "ObjectAnimator"
## The slot the object's animation group plays in.
const GROUP_SLOT := 0
## The first slot a free-controller clip plays in.
const FIRST_FREE_SLOT := 1
## The groups an object plays when no script has played one, first found wins.
const DEFAULT_GROUPS: Array[String] = ["Idle", "SpecialIdle"]

var _animator: KfAnimator = null
var _player: AnimationPlayer = null
## The group playing in GROUP_SLOT, as named to play_group(); "" for none.
var _group := ""


## The default group of a clip library: the first of DEFAULT_GROUPS it holds
## (case-insensitive), or "" when it holds none.
static func default_group(library: AnimationLibrary) -> String:
	for group in DEFAULT_GROUPS:
		if not _clip_named(library.get_animation_list(), group).is_empty():
			return group
	return ""


## Whether a clip library has anything an object animator can play: a
## sequence clip (any can be played as a group, PlayGroup), or an auto-play
## free-controller clip. A rig's library of library-only free controllers
## (skeleton.nif) has neither.
static func has_work(library: AnimationLibrary) -> bool:
	for clip in library.get_animation_list():
		var animation := library.get_animation(clip)
		if not bool(animation.get_meta("nif_free_controllers", false)):
			return true
		if bool(animation.get_meta("nif_autoplay", false)):
			return true
	return false


func _ready() -> void:
	var root := get_parent() as Node3D
	_player = root.get_node_or_null("AnimationPlayer") as AnimationPlayer if root != null else null
	if _player == null:
		return
	_animator = KfAnimator.new()
	_animator.name = "KfAnimator"
	add_child(_animator)
	_animator.node_root = _animator.get_path_to(root)
	_animator.clip_finished.connect(_on_clip_finished)
	if _group.is_empty():
		var library := _player.get_animation_library("")
		var default := default_group(library) if library != null else ""
		if not default.is_empty():
			play_group(default)
	elif not _start_group(_group):
		_group = ""
	_start_free_controllers()


## Plays `group` in GROUP_SLOT, replacing the group playing there. False when
## the object has no clip of that name (case-insensitive). Before this node is
## ready the group is kept and started when it is.
func play_group(group: String) -> bool:
	if _animator == null:
		_group = group
		return true
	if not _start_group(group):
		return false
	_group = group
	return true


## The group playing in GROUP_SLOT, as last played; "" for none.
func get_group() -> String:
	return _group


## The KfAnimator the clips play on; null before this node is ready or when
## the tree has no AnimationPlayer.
func get_animator() -> KfAnimator:
	return _animator


func _start_group(group: String) -> bool:
	var clip := _clip_named(_player.get_animation_list(), group)
	if clip.is_empty():
		return false
	return _animator.play(GROUP_SLOT, _player.get_animation(clip), 0.0, false, 1.0, clip, 0) != 0


func _start_free_controllers() -> void:
	var slot := FIRST_FREE_SLOT
	var finished: Array[int] = []
	for clip in _player.get_animation_list():
		var animation := _player.get_animation(clip)
		if not bool(animation.get_meta("nif_autoplay", false)):
			continue
		var speed := float(animation.get_meta("nif_frequency", 1.0))
		if _animator.play(slot, animation, 0.0, false, speed, String(clip), 0) == 0:
			continue
		var time := _creation_time(animation)
		_animator.seek(slot, time)
		if animation.loop_mode == Animation.LOOP_NONE and time >= animation.length:
			finished.append(slot)
		slot += 1
	# The pose at creation, before anything else moves or hides a part. A
	# clamped clip already at its end has nothing left to play: its end value
	# is written here once and its slot freed, so a later driver wins.
	_animator.update_pose()
	for done in finished:
		_animator.stop(done, 0.0)


## A free controller's clip time when the object is created. Gamebryo runs a
## controller at its own time, app time x frequency + phase, kept within its
## start and stop by its cycle type; the object's app time starts at 0. Keys
## are rebased to the controller's start (`nif_start_time`), so its time at
## creation, `phase`, is clip time phase - start: clamped into the clip for a
## clamped clip, wrapped for a looping one. A weapon's setup controllers run
## from -0.033 s to 0 s, so at creation they are already at their end, the
## rest pose. `# ASSUMPTION`: phase is in seconds and the object's time starts
## at 0 when it is created.
static func _creation_time(animation: Animation) -> float:
	var phase := float(animation.get_meta("nif_phase", 0.0))
	var start := float(animation.get_meta("nif_start_time", 0.0))
	var time := phase - start
	if not is_finite(time) or animation.length <= 0.0:
		return 0.0
	if animation.loop_mode == Animation.LOOP_NONE:
		return clampf(time, 0.0, animation.length)
	return fposmod(time, animation.length)


## A clamped clip reached its end: a free controller frees its slot (its values
## stay); the group holds its last frame. The stop is deferred: KfAnimator
## emits clip_finished while advancing and writes that frame's pose after, so
## stopping here would drop the clip before its end value is written, leaving
## the node one frame short of it (the hunting rifle's free controllers run
## from a displaced pose, -0.033 s, to its rest pose at 0 s: stopped early, its
## bolt stayed a few percent toward the displaced pose).
func _on_clip_finished(slot: int, _animation: Animation) -> void:
	if slot >= FIRST_FREE_SLOT:
		_animator.stop.call_deferred(slot, 0.0)


## The clip in `clips` whose name matches `group` ignoring case (scripts write
## `idle` and `Idle`), or "".
static func _clip_named(clips: PackedStringArray, group: String) -> String:
	var wanted := NifNames.escape(group).to_lower()
	for clip in clips:
		if String(clip).to_lower() == wanted:
			return String(clip)
	return ""
