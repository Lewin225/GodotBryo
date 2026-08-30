extends Node

# Issue #52 follow-up: real-data verification that NPCNode wires:
# 1. A real LocomotionAnimationPlayer holding EVERY real .kf found under
#    characters\_male\locomotion\ (not a hand-picked subset -- NOT
#    self-contained embedded animation either, see nif_loader.cpp's own
#    extract_sequence() doc comment for the real bare-NiControllerSequence
#    shape this required a native fix for), each under its own real
#    relative path as its clip name (no remapping to invented aliases).
# 2. A real AnimationTree layering the cardinal-direction "mt" clips
#    (legs) under a fixed upper-body pose (spine/arms/head), driven
#    continuously by set_move_input(Vector2) -- real blendspace work, not
#    discrete clip switching -- with root-bone translation stripped (real
#    Bethesda root-motion-extraction convention, confirmed via direct
#    review, not a wrong-file guess).

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

	var skeleton: Skeleton3D = node.get_node_or_null(^"Body/Skeleton3D")
	check(skeleton != null, "found the real Skeleton3D")
	if skeleton != null:
		var bip01 := skeleton.find_bone("Bip01")
		var root_has_translation := false
		for i in anim.get_track_count():
			if anim.track_get_type(i) == Animation.TYPE_POSITION_3D and String(anim.track_get_path(i)).ends_with(":Bip01"):
				root_has_translation = true
		check(not root_has_translation, "real root-bone (Bip01) translation stripped from 'male__mtforward.kf' -- see mesh_resolver.gd's _strip_root_bone_translation() doc comment")

	# --- Real AnimationTree layering ---
	var tree: AnimationTree = node.get_node_or_null(^"Body/LocomotionAnimationTree")
	check(tree != null, "a real LocomotionAnimationTree was built")
	if tree == null:
		_finish()
		return
	check(tree.active, "the tree is active")
	var tree_root := tree.tree_root
	check(tree_root is AnimationNodeBlendTree, "tree_root is a real AnimationNodeBlendTree")
	if tree_root is AnimationNodeBlendTree:
		check(tree_root.has_node("Locomotion"), "'Locomotion' blend space node exists")
		check(tree_root.has_node("UpperBodyPose"), "'UpperBodyPose' node exists")
		check(tree_root.has_node("UpperBodyLayer"), "'UpperBodyLayer' filtered blend node exists")
		var locomotion: AnimationNode = tree_root.get_node("Locomotion")
		check(locomotion is AnimationNodeBlendSpace2D and locomotion.get_blend_point_count() == 5,
				"Locomotion blend space has all 5 real points (4 cardinal + idle, got %d)" % (locomotion.get_blend_point_count() if locomotion is AnimationNodeBlendSpace2D else -1))
		var upper_layer: AnimationNode = tree_root.get_node("UpperBodyLayer")
		if upper_layer is AnimationNodeBlend2:
			check(upper_layer.filter_enabled, "UpperBodyLayer has real bone filtering enabled")
			if skeleton != null:
				# Relative to the SAME parent populate_locomotion_tree()
				# itself used to build its filter paths ("Body"), not `node`.
				var body_node: Node = node.get_node(^"Body")
				var skel_path: NodePath = body_node.get_path_to(skeleton)
				var spine_path := NodePath(str(skel_path) + ":Bip01 Spine1")
				var leg_path := NodePath(str(skel_path) + ":Bip01 L Thigh")
				check(upper_layer.is_path_filtered(spine_path), "upper-body bone (Bip01 Spine1) IS filtered into the upper-body layer")
				check(not upper_layer.is_path_filtered(leg_path), "leg bone (Bip01 L Thigh) is NOT filtered -- legs stay driven by Locomotion alone")

	# set_move_input() sets the real blend_position parameter -- Input.get_vector()
	# convention (y negative = forward) flipped to the blend space's own
	# Y-positive-is-forward point layout.
	node.set_move_input(Vector2(0.0, -1.0)) # forward
	check(tree.get("parameters/Locomotion/blend_position") == Vector2(0.0, 1.0),
			"Vector2(0,-1) (forward, Input.get_vector convention) sets blend_position to (0,1)")

	node.set_move_input(Vector2(1.0, 0.0)) # right
	check(tree.get("parameters/Locomotion/blend_position") == Vector2(1.0, 0.0),
			"Vector2(1,0) (right) sets blend_position to (1,0)")

	node.set_move_input(Vector2(3.0, 4.0)) # well past the blend space's own sample points
	var clamped: Vector2 = tree.get("parameters/Locomotion/blend_position")
	check(is_equal_approx(clamped.length(), 1.0), "an over-length input is clamped to length 1 (got length %.3f)" % clamped.length())

	# --- Real playback behavior: process a few frames and confirm the leg
	# pose actually changes over time while playing forward (proof the
	# tree really drives the skeleton, not just that parameters are set).
	node.set_move_input(Vector2(0.0, -1.0))
	await get_tree().process_frame
	await get_tree().process_frame
	var thigh_idx := skeleton.find_bone("Bip01 L Thigh") if skeleton != null else -1
	var pose_a := skeleton.get_bone_pose_rotation(thigh_idx) if thigh_idx != -1 else Quaternion.IDENTITY
	for i in 10:
		await get_tree().process_frame
	var pose_b := skeleton.get_bone_pose_rotation(thigh_idx) if thigh_idx != -1 else Quaternion.IDENTITY
	check(thigh_idx != -1 and not pose_a.is_equal_approx(pose_b), "the leg's actual bone pose changes over time while 'forward' plays (real animation, not a static parameter)")

	# Real regression guard for a real user-reported bug: with only 5
	# points in an exact "plus" shape (4 cardinals + center, all
	# axis-aligned), AnimationNodeBlendSpace2D's own auto-triangulation
	# produced a working blend for "right" but a frozen/wrong one for
	# "left" -- despite mtleft.kf carrying the exact same real 58-track
	# full leg data as mtforward/mtright (confirmed real, not a data gap).
	# Fixed with an explicit fan triangulation (auto_triangles = false +
	# 4 manual add_triangle() calls). Verify every real cardinal direction
	# (except backward, whose own real data has no leg tracks at all --
	# confirmed separately) produces comparable, non-trivial pelvis motion.
	if thigh_idx != -1:
		var pelvis_idx := skeleton.find_bone("Bip01 Pelvis")
		var deltas := {}
		for dirname in ["forward", "left", "right"]:
			var input: Vector2
			match dirname:
				"forward": input = Vector2(0.0, -1.0)
				"left": input = Vector2(-1.0, 0.0)
				"right": input = Vector2(1.0, 0.0)
			node.set_move_input(input)
			await get_tree().process_frame
			await get_tree().process_frame
			var start := skeleton.get_bone_pose_rotation(pelvis_idx)
			for f in 15:
				await get_tree().process_frame
			deltas[dirname] = start.angle_to(skeleton.get_bone_pose_rotation(pelvis_idx))
		for dirname in deltas:
			check(deltas[dirname] > 0.01, "'%s' produces real, non-trivial pelvis motion (angle delta=%.4f) -- not frozen by a bad blend-space triangulation" % [dirname, deltas[dirname]])

	# Real regression guard for a real user-reported bug: "Bip01 NonAccum"
	# (the true parent of the whole rest of the skeleton) has no track at
	# all in mtidle.kf/mtbackward.kf but does in mtforward/mtleft/mtright
	# (confirmed real, baseline ~0.93), and its own REST position is
	# (0,0,0) -- sweeping blend weight between idle and forward used to
	# interpolate NonAccum from that (0,0,0) rest default toward ~0.93,
	# which (since everything else hangs off NonAccum) made the WHOLE
	# character's global pose rise proportional to blend weight ("floats
	# up into the air... by the weight of the blend"). Fixed by stripping
	# NonAccum's own translation track the same way the root bone's is
	# stripped -- verify it now stays put across the full weight sweep.
	var non_accum_idx := skeleton.find_bone("Bip01 NonAccum") if skeleton != null else -1
	var pelvis_idx := skeleton.find_bone("Bip01 Pelvis") if skeleton != null else -1
	if non_accum_idx != -1 and pelvis_idx != -1:
		var pelvis_global_at_idle: Vector3
		var drift_found := false
		for w in [0.0, 0.25, 0.5, 0.75, 1.0]:
			tree.set("parameters/Locomotion/blend_position", Vector2(0.0, w))
			for f in 3:
				await get_tree().process_frame
			var na_pos := skeleton.get_bone_pose_position(non_accum_idx)
			if not na_pos.is_equal_approx(Vector3.ZERO):
				drift_found = true
			var pelvis_global := skeleton.get_bone_global_pose(pelvis_idx).origin
			if w == 0.0:
				pelvis_global_at_idle = pelvis_global
			elif not pelvis_global.is_equal_approx(pelvis_global_at_idle):
				drift_found = true
		check(not drift_found, "sweeping blend weight from idle to forward does NOT make NonAccum (or anything hanging off it) drift -- real fix for the reported float-up bug")

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
