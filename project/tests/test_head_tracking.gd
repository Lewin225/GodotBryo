extends Node3D

## ActorHeadTracking's rules (Plans/Actors/head_tracking.md) with Doc Mitchell
## and Sunny Smiles physicalised in Doc's house: the default target is the
## nearest actor in front within range (indoors 200 units), not one behind;
## Look overrides it until StopLook; in conversation each looks at the other;
## a package with Head Tracking Off turns the modifier off.

const FRAMES := 120 * 60

var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	ScriptServer.player_reference = EsmServer.get_player_reference()
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var sunny := EsmServer.find_reference_by_editor_id("SunnyRef") as ActorReference
	for actor in [doc, sunny]:
		NpcSimulationServer.package_runner.untrack(actor)
	NpcSimulationServer.local_navigation.set_local_cells(doc.current_space_form_id, PackedInt32Array([doc.current_space_form_id]))
	var physicaliser := EsmReferencePhysicaliser.new()
	var doc_node := physicaliser.physicalise(doc, self) as NpcController
	_place_beside(sunny, doc, doc_node, 2.0)
	var sunny_node := physicaliser.physicalise(sunny, self) as NpcController
	await _wait_until(func() -> bool: return _tracking(doc_node) != null and _tracking(doc_node).get_modifier() != null and _tracking(sunny_node) != null and _tracking(sunny_node).get_modifier() != null)
	# The default rule only runs within max_distance_from_player_units of the
	# player, so the player stands where Doc does.
	ScriptServer.move_reference(ScriptServer.player_reference, doc.current_space_form_id, doc.position, Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	var tracking := _tracking(doc_node)

	await _settle()
	check(tracking.get_target() == sunny and tracking.get_modifier().active, "with Sunny 2 m in front, Doc looks at her (%s)" % _name(tracking.get_target()))
	var aim := doc_node.find_child(ActorHeadTracking.AIM_NODE_NAME, true, false) as Node3D
	check(aim.global_position.distance_to(_tracking(sunny_node).get_eye_position()) < 0.05, "his look point sits at her eyes (%.3f m off)" % aim.global_position.distance_to(_tracking(sunny_node).get_eye_position()))

	_place_beside(sunny, doc, doc_node, -2.0)
	ScriptServer.apply_pending_moves()
	tracking._default_held_until_msec = 0
	await _settle()
	check(tracking.get_target() == null, "with Sunny 2 m behind, he does not (%s)" % _name(tracking.get_target()))

	ScriptServer.run_debug_line("DocMitchellREF.Look SunnyRef")
	await _settle()
	check(doc.look_target == sunny and tracking.get_target() == sunny, "Look SunnyRef turns him to her even behind him (%s)" % _name(tracking.get_target()))
	for frame in 90:
		await get_tree().process_frame
	var turn := await _head_turn_degrees(doc_node, tracking)
	check(turn <= tracking.left_right_limit_degrees * 0.5 + 5.0, "but his head turns no further than the left-right limit allows (%.0f degrees from his body's forward; limit %.0f each way)" % [turn, tracking.left_right_limit_degrees * 0.5])
	ScriptServer.run_debug_line("DocMitchellREF.StopLook")
	await _settle()
	check(doc.look_target == null and tracking.get_target() == null, "StopLook returns him to the default rule (%s)" % _name(tracking.get_target()))

	DialogueServer._conversation_speaker = doc
	DialogueServer._conversation_listener = sunny
	await _settle()
	check(tracking.get_target() == sunny and _tracking(sunny_node).get_target() == doc, "in conversation each looks at the other (%s, %s)" % [_name(tracking.get_target()), _name(_tracking(sunny_node).get_target())])
	DialogueServer._conversation_speaker = null
	DialogueServer._conversation_listener = null

	# A line said outside a conversation: Sunny is behind Doc.
	var line := DialogueLine.new()
	line.speaker = doc
	line.listener = sunny
	DialogueServer.response_started.emit(line, "")
	await _settle()
	check(tracking.get_target() == sunny, "while Doc says a line to Sunny he looks at her, behind him or not (%s)" % _name(tracking.get_target()))
	DialogueServer.line_finished.emit(line)
	await _settle()
	check(tracking.get_target() == sunny, "and keeps looking for line_linger_seconds after it ends, in case another follows (%s)" % _name(tracking.get_target()))
	tracking._line_partner_until_msec = 0
	await _settle()
	check(tracking.get_target() == null, "then returns to the default rule (%s)" % _name(tracking.get_target()))

	var locked := PackageBase.new()
	locked.general_flags = PackageBase.GENERAL_FLAG_HEAD_TRACKING_OFF
	doc.active_package = locked
	doc.look_target = sunny
	await _settle()
	check(not tracking.get_modifier().active and tracking.get_target() == null, "a package with Head Tracking Off turns the modifier off, even over Look")
	doc.active_package = null
	doc.look_target = null

	# Seated, with nothing to look at, he looks ahead of his seated body (out
	# of the chair), not ahead of the controller (back over it).
	_place_beside(sunny, doc, doc_node, -20.0)
	var chair := EsmServer.find_reference_by_editor_id("DocMitchellChairREF") as FurnitureReference
	ScriptServer.begin_use(doc, chair)
	await _wait_until(func() -> bool: return doc_node.actor.animator.get_idle() != null and doc_node.actor.animator.get_idle().editor_id == "ChairDynamicIdle")
	ScriptServer.apply_pending_moves()
	await _settle()
	var chair_position := EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * chair.position
	var head := tracking.get_eye_position()
	var look_point := (doc_node.find_child(ActorHeadTracking.AIM_NODE_NAME, true, false) as Node3D).global_position
	check(tracking.get_target() == null and look_point.distance_to(chair_position) > head.distance_to(chair_position), "seated with nothing to look at, his look point is out of the chair, not over its back (%.2f m from the chair against his head's %.2f)" % [look_point.distance_to(chair_position), head.distance_to(chair_position)])
	ScriptServer.end_use(doc)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Moves `actor` `metres` along `beside`'s facing (-Z) from it (negative:
## behind).
func _place_beside(actor: ActorReference, beside: ActorReference, beside_node: Node3D, metres: float) -> void:
	var facing := -beside_node.global_basis.z
	facing.y = 0.0
	var offset := EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS.inverse() * (facing.normalized() * metres)
	ScriptServer.move_reference(actor, beside.current_space_form_id, beside.position + offset, beside.rotation)
	ScriptServer.apply_pending_moves()

## How far, left or right, Doc's head faces from his body's forward (towards
## the default aim point), degrees. Read in skeleton_updated: the look-at's
## turn exists only during that signal.
func _head_turn_degrees(doc_node: NpcController, tracking: ActorHeadTracking) -> float:
	var skeleton := doc_node.find_child("Skeleton3D", true, false) as Skeleton3D
	var bone := skeleton.find_bone(ActorHeadTracking.HEAD_BONE_NAME)
	var captured := [Transform3D()]
	var capture := func() -> void: captured[0] = skeleton.global_transform * skeleton.get_bone_global_pose(bone)
	skeleton.skeleton_updated.connect(capture)
	await get_tree().process_frame
	await get_tree().process_frame
	skeleton.skeleton_updated.disconnect(capture)
	var head: Transform3D = captured[0]
	var head_forward := head.basis.y
	var body_forward := tracking._default_aim_position() - tracking.get_eye_position()
	return rad_to_deg(absf(Vector2(head_forward.x, head_forward.z).angle_to(Vector2(body_forward.x, body_forward.z))))

func _tracking(node: NpcController) -> ActorHeadTracking:
	return node.actor.head_tracking if node != null and node.actor != null else null

func _settle() -> void:
	for frame in 40:
		await get_tree().process_frame

func _name(reference: EsmReference) -> String:
	if reference == null:
		return "none"
	return reference.base.editor_id if reference.base != null else reference.instance_id

func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame
