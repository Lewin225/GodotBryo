extends Node3D

## KfAnimator's sync mode (Plans/Actors/first_person.md, Sync mode). With
## built clips: a start emits clip_started with its path and serial, stop and
## stop_all emit clip_stopped, announce reports a start with nothing playing;
## a follower clip played with the source's serial keeps the source's time,
## through a seek, a loop section and the end, and emits no text_key or
## clip_finished, and runs on its own clock (with its events) once the source's
## clip is gone. With real KFs through KfClipSync: the third-person standing
## idle, announced on the source, plays `_1stperson/mtidle.kf` on the follower,
## following the source's clock once the source plays it too; a third-person
## KF with no first-person file whose clip keys only bones both skeletons have
## leaves the follower's slot empty, or plays that clip with filter_fallback
## off; the VCG01 wake-up (a `_male` KF that also keys Camera1st, which only the
## follower has), played on the source, plays its own clip on the follower;
## SAME_CLIP plays the source's clip as it is.
## disabled_bones: a disabled bone keeps its pose while a clip keys it.

const TIMEOUT_MSEC := 30000
const SLOT := 1
const MALE_IDLE := "characters/_male/locomotion/mtidle.kf"
const FIRST_PERSON_IDLE := "characters/_1stperson/mtidle.kf"
## A _male KF with no file at the same path below _1stperson (BSA listing).
const MALE_ONLY := "characters/_male/idleanims/nvdlc01_talk_headshake_emphatic.kf"
## VCG01's wake-up (LooseVCG01PlayerWakeup's MODL): keys only Camera1st, and has
## no file below _1stperson.
const WAKEUP := "characters/_male/idleanims/specialidle_nvcg01playerwakeup.kf"
## Bones the built clips and mtidle.kf key.
const BONES := ["Bip01", "Bip01 NonAccum", "Bip01 Spine", "Bip01 Spine1", "Bip01 Spine2", "Bip01 L UpperArm", "Camera1st"]

var failures := 0
var _started: Array = []
var _stopped: Array = []
var _follower_events: Array = []
var _source_finished := 0
var _delivered: Array = []


func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1


func _ready() -> void:
	await _check_built_clips()
	await _check_clip_sync()
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)


## A chain of BONES; without Camera1st for `third_person`.
func _skeleton(third_person := false) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	for bone_name: String in BONES:
		if third_person and bone_name == "Camera1st":
			continue
		skeleton.add_bone(bone_name)
	for bone in range(1, skeleton.get_bone_count()):
		skeleton.set_bone_parent(bone, bone - 1)
	add_child(skeleton)
	skeleton.reset_bone_poses()
	return skeleton


func _animator(skeleton: Skeleton3D) -> KfAnimator:
	var animator := KfAnimator.new()
	add_child(animator)
	animator.skeleton_path = animator.get_path_to(skeleton)
	return animator


## A clip of `length` seconds turning Bip01 Spine, with a text key at 0.5 s.
static func _clip(length: float) -> Animation:
	var animation := Animation.new()
	animation.length = length
	var track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(track, NodePath("Bip01 Spine"))
	animation.rotation_track_insert_key(track, 0.0, Quaternion.IDENTITY)
	animation.rotation_track_insert_key(track, length, Quaternion(Vector3.UP, 1.0))
	animation.set_meta("nif_track_priorities", {"Bip01 Spine": 20})
	animation.set_meta("nif_text_keys", [{"time": 0.5, "value": "Hit"}])
	return animation


func _on_kf_delivered(library: AnimationLibrary) -> void:
	_delivered.append(library)


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


func _check_built_clips() -> void:
	var source := _animator(_skeleton())
	var follower := _animator(_skeleton())
	follower.sync_source = follower.get_path_to(source)
	follower.process_priority = source.process_priority + 1
	source.clip_started.connect(func(slot: int, path: String, animation: Animation, serial: int, fade: float, keep_root: bool, speed: float) -> void:
		_started.append([slot, path, animation, serial, fade, keep_root, speed]))
	source.clip_stopped.connect(func(slot: int, fade: float) -> void:
		_stopped.append([slot, fade]))
	source.clip_finished.connect(func(_slot: int, _animation: Animation) -> void:
		_source_finished += 1)
	follower.clip_finished.connect(func(slot: int, _animation: Animation) -> void:
		_follower_events.append(["finished", slot]))
	follower.text_key.connect(func(slot: int, key: String, _time: float) -> void:
		_follower_events.append([key, slot]))

	var clip := _clip(2.0)
	var serial := source.play(SLOT, clip, 0.25, true, 1.0, "characters/_male/test.kf")
	check(serial > 0, "play returns the start's serial")
	check(_started.size() == 1 and _started[0] == [SLOT, "characters/_male/test.kf", clip, serial, 0.25, true, 1.0],
			"play emits clip_started(slot, path, animation, serial, fade, keep_root, speed): %s" % [_started])
	check(source.get_start(SLOT).get("path", "") == "characters/_male/test.kf" and int(source.get_start(SLOT).get("serial", 0)) == serial,
			"get_start reports the slot's start")
	check(source.play(SLOT, Animation.new(), 0.1, true, 1.0, "x.kf") == 0 and _started.size() == 1,
			"a clip keying no bone starts nothing and emits nothing")

	await _frames(10)
	var follower_serial := follower.play(SLOT, clip, 0.1, false, 1.0, "characters/_1stperson/test.kf", serial)
	check(follower_serial > 0, "the follower plays with the source's serial")
	check(is_equal_approx(follower.get_time(SLOT), source.get_time(SLOT)),
			"a late follower starts at the source's time (%.3f, %.3f)" % [follower.get_time(SLOT), source.get_time(SLOT)])
	await _frames(20)
	check(is_equal_approx(follower.get_time(SLOT), source.get_time(SLOT)),
			"the follower keeps the source's time (%.3f, %.3f)" % [follower.get_time(SLOT), source.get_time(SLOT)])
	source.seek(SLOT, 0.2)
	source.set_loop_section(SLOT, 0.2, 0.4, -1)
	await _frames(40)
	check(is_equal_approx(follower.get_time(SLOT), source.get_time(SLOT)) and follower.get_time(SLOT) <= 0.4,
			"a seek and loop section on the source carry to the follower (%.3f, %.3f)" % [follower.get_time(SLOT), source.get_time(SLOT)])
	source.set_loop_section(SLOT, 0.0, -1.0, 0)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while _source_finished == 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await _frames(2)
	check(_source_finished == 1 and is_equal_approx(follower.get_time(SLOT), 2.0), "the follower holds the source clip's end")
	check(_follower_events.is_empty(), "a following clip emits no text_key or clip_finished: %s" % [_follower_events])

	source.stop(SLOT, 0.0)
	check(_stopped == [[SLOT, 0.0]], "stop emits clip_stopped(slot, fade): %s" % [_stopped])
	check(source.get_start(SLOT).is_empty(), "a stopped slot has no start")
	follower.seek(SLOT, 0.0)
	deadline = Time.get_ticks_msec() + TIMEOUT_MSEC
	while follower.get_time(SLOT) <= 0.6 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(follower.get_time(SLOT) > 0.6, "with the source's clip gone the follower runs its own clock")
	check(_follower_events.has(["Hit", SLOT]), "on its own clock the follower emits its text keys")

	var announced := source.announce(SLOT, MALE_IDLE, clip, 0.0, true, 1.0)
	check(announced > serial and source.get_animation(SLOT) == null, "announce starts nothing")
	check(_started.back() == [SLOT, MALE_IDLE, clip, announced, 0.0, true, 1.0], "announce emits clip_started with its clip")
	check(source.get_start(SLOT).get("played", true) == false, "get_start marks an announced start not played")
	check(source.get_started_slots() == PackedInt32Array([SLOT]) and source.get_slots().is_empty(),
			"an announced slot is started but plays nothing")
	_stopped.clear()
	source.stop_all()
	check(_stopped == [[SLOT, 0.0]], "stop_all emits clip_stopped for each started slot")

	var skeleton := source.get_node(source.skeleton_path) as Skeleton3D
	var spine := skeleton.find_bone("Bip01 Spine")
	skeleton.set_bone_pose_rotation(spine, Quaternion.IDENTITY)
	source.disabled_bones = PackedStringArray(["Bip01 Spine"])
	source.play(SLOT, clip, 0.0, true, 1.0)
	source.seek(SLOT, 1.5)
	source.update_pose()
	check(skeleton.get_bone_pose_rotation(spine).is_equal_approx(Quaternion.IDENTITY), "a disabled bone is not written")
	source.disabled_bones = PackedStringArray()
	source.update_pose()
	check(not skeleton.get_bone_pose_rotation(spine).is_equal_approx(Quaternion.IDENTITY), "re-enabled, it is written")
	source.queue_free()
	follower.queue_free()


func _load(path: String) -> Animation:
	_delivered.clear()
	NifServer.request_kf(path, self, _on_kf_delivered)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while _delivered.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var library: AnimationLibrary = _delivered[0] if not _delivered.is_empty() else null
	if library == null or library.get_animation_list().is_empty():
		return null
	return library.get_animation(library.get_animation_list()[0])


func _check_clip_sync() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var source := _animator(_skeleton(true))
	var follower := _animator(_skeleton())
	var sync := KfClipSync.new()
	sync.follower = follower
	add_child(sync)
	check(sync.remap_path(MALE_IDLE) == FIRST_PERSON_IDLE, "the default remap sends the standing idle to _1stperson's root")
	check(sync.remap_path("meshes\\characters\\_male\\locomotion\\mtforward.kf") == "characters/_1stperson/locomotion/mtforward.kf",
			"other _male paths keep their relative path")
	check(sync.remap_path("characters/_1stperson/specialidle_nvcg01playerwakeup.kf") == "characters/_1stperson/specialidle_nvcg01playerwakeup.kf",
			"a path no pair matches is unchanged")
	sync.set_source(source)
	check(follower.process_priority > source.process_priority, "set_source places the follower after the source")

	var announced := source.announce(SLOT, MALE_IDLE, null, 0.0, true, 1.0)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while follower.get_animation(SLOT) == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(follower.get_animation(SLOT) != null, "an announced start plays its first-person file on the follower")
	check(follower.get_start(SLOT).get("path", "") == FIRST_PERSON_IDLE, "the follower's start names the remapped path")
	check(int(announced) > 0 and source.get_animation(SLOT) == null, "the source still plays nothing")

	# The same KF on the source (it keys the built skeleton's spine), so the
	# follower takes its clock.
	var male_idle: Animation = await _load(MALE_IDLE)
	check(male_idle != null, "NifServer delivers " + MALE_IDLE)
	if male_idle != null:
		source.play(SLOT, male_idle, 0.0, true, 1.0, MALE_IDLE)
		await _frames(5)
		source.seek(SLOT, 1.5)
		await _frames(3)
		check(absf(follower.get_time(SLOT) - source.get_time(SLOT)) < 0.001,
				"the follower plays on the source's clock (%.3f, %.3f)" % [follower.get_time(SLOT), source.get_time(SLOT)])

	var gesture := _clip(2.0)
	source.play(SLOT, gesture, 0.0, true, 1.0, MALE_ONLY)
	await _frames(30)
	check(follower.get_animation(SLOT) == null and follower.get_started_slots().is_empty(),
			"a start with no first-person file, keying only shared bones, leaves the follower's slot empty")
	sync.filter_fallback = false
	source.play(SLOT, gesture, 0.0, true, 1.0, MALE_ONLY)
	await _frames(30)
	check(follower.get_animation(SLOT) == gesture, "with filter_fallback off it plays the source's clip")
	sync.filter_fallback = true

	var wakeup: Animation = await _load(WAKEUP)
	check(wakeup != null, "NifServer delivers " + WAKEUP)
	var played := source.play(SLOT, wakeup, 0.0, true, 1.0, WAKEUP) if wakeup != null else 0
	check(played > 0, "the source plays the wake-up (its static neck and arm poses)")
	deadline = Time.get_ticks_msec() + TIMEOUT_MSEC
	while follower.get_animation(SLOT) != wakeup and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(wakeup != null and follower.get_animation(SLOT) == wakeup,
			"the wake-up, with no first-person file and keying Camera1st, plays its own clip on the follower")
	check(follower.get_start(SLOT).get("path", "") == WAKEUP, "under its own path")
	source.seek(SLOT, 1.0)
	await _frames(3)
	check(absf(follower.get_time(SLOT) - source.get_time(SLOT)) < 0.001, "on the source's clock")

	sync.mode = KfClipSync.Mode.SAME_CLIP
	sync.set_source(source)
	source.stop_all()
	if male_idle != null:
		source.play(SLOT, male_idle, 0.0, true, 1.0, MALE_IDLE)
		check(follower.get_animation(SLOT) == male_idle, "SAME_CLIP plays the source's own clip")
	source.stop_all()
	sync.set_source(null)
