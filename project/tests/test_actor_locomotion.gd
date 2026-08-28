extends Node

# Issue #52 follow-up: real-data verification that NPCNode wires a real
# LocomotionAnimationPlayer holding EVERY real .kf found under
# characters\_male\locomotion\ (not a hand-picked subset -- NOT
# self-contained embedded animation either, see nif_loader.cpp's own
# extract_sequence() doc comment for the real bare-NiControllerSequence
# shape this required a native fix for), each under its own real relative
# path as its clip name (no remapping to invented aliases), and that
# set_move_input(Vector2) switches between the real base "mt" cardinal
# clips (+ shared idle) correctly.

const DATA_DIR := "../fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var placement: Dictionary = esm.get_actor_by_form_id(0x00104C0C) # Doc Mitchell
	check(not placement.is_empty(), "resolved Doc Mitchell directly by FormID")

	var node: NPCNode = registry.build(placement)
	check(node != null and node is NPCNode, "registry built a real NPCNode")
	if node == null:
		_finish()
		return
	add_child(node)

	var player: AnimationPlayer = node.get_node_or_null(^"Body/LocomotionAnimationPlayer")
	check(player != null, "a real LocomotionAnimationPlayer was built")
	if player == null:
		_finish()
		return

	# Real data: Doc Mitchell is male -- every real clip under
	# characters\_male\locomotion\ should be loaded, not just the base "mt"
	# cardinal set (real weapon-type-specific sets too -- 1hm/1hp/2ha/...).
	check(player.get_animation_list().size() > 50, "far more than just the 5 base cardinal clips loaded (got %d)" % player.get_animation_list().size())
	for clip_name in ["mtidle.kf", "male__mtforward.kf", "male__mtbackward.kf", "male__mtleft.kf", "male__mtright.kf"]:
		check(player.has_animation(clip_name), "real clip '%s' resolved under its own real name" % clip_name)
	check(player.has_animation("female__mtforward.kf"), "the OTHER gender's clips are also loaded (not just Doc Mitchell's own)")
	check(player.has_animation("1hmforward.kf"), "weapon-type-specific sets (e.g. 1hm) are also loaded, not dropped")

	var anim: Animation = player.get_animation("male__mtforward.kf")
	check(anim != null and anim.get_track_count() > 0, "'male__mtforward.kf' clip has real bone tracks (got %d)" % (anim.get_track_count() if anim else -1))

	# set_move_input() direction selection -- Input.get_vector() convention:
	# y negative = forward, y positive = backward, x positive = right.
	# Doc Mitchell is male, so it should target the "male__" clips.
	node.set_move_input(Vector2(0.0, -1.0))
	check(player.current_animation == "male__mtforward.kf", "Vector2(0,-1) selects 'male__mtforward.kf' (got '%s')" % player.current_animation)

	node.set_move_input(Vector2(0.0, 1.0))
	check(player.current_animation == "male__mtbackward.kf", "Vector2(0,1) selects 'male__mtbackward.kf' (got '%s')" % player.current_animation)

	node.set_move_input(Vector2(1.0, 0.0))
	check(player.current_animation == "male__mtright.kf", "Vector2(1,0) selects 'male__mtright.kf' (got '%s')" % player.current_animation)

	node.set_move_input(Vector2(-1.0, 0.0))
	check(player.current_animation == "male__mtleft.kf", "Vector2(-1,0) selects 'male__mtleft.kf' (got '%s')" % player.current_animation)

	node.set_move_input(Vector2(0.02, 0.01)) # inside the deadzone
	check(player.current_animation == "mtidle.kf", "near-zero input selects the shared 'mtidle.kf' (got '%s')" % player.current_animation)

	# Switching to the SAME direction twice shouldn't restart playback --
	# real regression guard against calling play() every frame.
	node.set_move_input(Vector2(0.0, -1.0))
	var pos_before := player.current_animation_position
	node.set_move_input(Vector2(0.0, -1.0))
	check(player.current_animation == "male__mtforward.kf" and player.current_animation_position == pos_before,
			"re-selecting the same direction doesn't restart the clip (position unchanged)")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)

func _finish() -> void:
	print("=======================")
	print("FAILURES: ", failures)
	get_tree().quit(1)
