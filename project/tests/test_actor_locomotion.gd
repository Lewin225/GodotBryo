extends Node

# Issue #52 follow-up: real-data verification that NPCNode wires a real
# LocomotionAnimationPlayer from standalone movement .kf files (NOT
# self-contained embedded animation -- see nif_loader.cpp's own
# extract_sequence() doc comment for the real bare-NiControllerSequence
# shape this required a native fix for) and that set_move_input(Vector2)
# switches between the 4 real cardinal clips (+ idle) correctly.

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

	var player: AnimationPlayer = node.get_node_or_null(^"LocomotionAnimationPlayer")
	check(player != null, "a real LocomotionAnimationPlayer was built")
	if player == null:
		_finish()
		return

	# Real data: Doc Mitchell is male -- all 5 clips (idle + 4 cardinal
	# directions) should have resolved from real .kf files.
	for clip_name in ["idle", "forward", "backward", "left", "right"]:
		check(player.has_animation(clip_name), "real clip '%s' resolved" % clip_name)

	var anim: Animation = player.get_animation("forward")
	check(anim != null and anim.get_track_count() > 0, "'forward' clip has real bone tracks (got %d)" % (anim.get_track_count() if anim else -1))

	# set_move_input() direction selection -- Input.get_vector() convention:
	# y negative = forward, y positive = backward, x positive = right.
	node.set_move_input(Vector2(0.0, -1.0))
	check(player.current_animation == "forward", "Vector2(0,-1) selects 'forward' (got '%s')" % player.current_animation)

	node.set_move_input(Vector2(0.0, 1.0))
	check(player.current_animation == "backward", "Vector2(0,1) selects 'backward' (got '%s')" % player.current_animation)

	node.set_move_input(Vector2(1.0, 0.0))
	check(player.current_animation == "right", "Vector2(1,0) selects 'right' (got '%s')" % player.current_animation)

	node.set_move_input(Vector2(-1.0, 0.0))
	check(player.current_animation == "left", "Vector2(-1,0) selects 'left' (got '%s')" % player.current_animation)

	node.set_move_input(Vector2(0.02, 0.01)) # inside the deadzone
	check(player.current_animation == "idle", "near-zero input selects 'idle' (got '%s')" % player.current_animation)

	# Switching to the SAME direction twice shouldn't restart playback --
	# real regression guard against calling play() every frame.
	node.set_move_input(Vector2(0.0, -1.0))
	var pos_before := player.current_animation_position
	node.set_move_input(Vector2(0.0, -1.0))
	check(player.current_animation == "forward" and player.current_animation_position == pos_before,
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
