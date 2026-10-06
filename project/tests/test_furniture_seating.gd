extends Node3D

## Furniture use (Plans/Actors/stage_g.md steps 1 and 3): the idle tree picks
## the chair's enter, sitting and stand-up idles for Doc in his chair by sit
## state and marker ID; using the chair seats him at its marker (GetSitting 3,
## GetFurnitureMarkerID 14) and leaving it stands him; his VCG01 stage 80 Travel
## package ends with him seated, off screen.

const SPEED_SCALE := 10.0
const FRAMES := 30 * 60
## Frames allowed for Doc's visual and locomotion KFs to load.
const VISUAL_FRAMES := 120 * 60
const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")

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
	NpcSimulationServer.low_level_travel.speed_scale = SPEED_SCALE
	ScriptServer.player_reference = EsmServer.get_player_reference()
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var chair := EsmServer.find_reference_by_editor_id("DocMitchellChairREF") as FurnitureReference
	NpcSimulationServer.package_runner.untrack(doc)

	check(ScriptServer.begin_use(doc, chair), "Doc starts using his chair")
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.SITTING)
	ScriptServer.apply_pending_moves()
	var placement := ScriptServer.furniture_seating.get_placement(chair, doc.using_marker)
	check(not placement.is_empty() and doc.position.distance_to(placement["position"]) < 0.01, "he is seated at the chair's marker (%s, marker at %s)" % [doc.position, placement.get("position")])
	check(_run("DocMitchellREF.GetSitting") == 3 and _run("DocMitchellREF.GetFurnitureMarkerID") == 14, "GetSitting is 3 and GetFurnitureMarkerID 14 (%s, %s)" % [_run("DocMitchellREF.GetSitting"), _run("DocMitchellREF.GetFurnitureMarkerID")])

	var root := ScriptServer.idle_tree.get_root(IdleTree.FURNITURE_ROOT)
	var expected := [[2, "ChairFrontSit", "Chair_ForwardEnter.kf"], [1, "ChairDynamicIdle", "DynamicIdle_ChairSit.kf"], [4, "ChairFrontStand", "Chair_ForwardExit.kf"]]
	for row in expected:
		doc.sit_state = row[0]
		var picked := ScriptServer.idle_tree.pick(doc, root)
		check(picked != null and picked.editor_id == row[1] and picked.model_path.get_file() == row[2], "sit state %d picks %s, %s (%s)" % [row[0], row[1], row[2], _describe(picked)])
	var quest := EsmServer.find_base_by_editor_id("VCG01")
	var state := QuestServer.get_quest_state(quest)
	QuestServer.start_quest(quest)
	state.stage = 40
	var early := ScriptServer.idle_tree.pick(doc, root)
	check(early != null and early.editor_id == "NVchairStandDoc", "at VCG01 stage 40 standing up picks NVchairStandDoc first (%s)" % _describe(early))
	state.stage = 0
	doc.sit_state = FurnitureSeating.SITTING

	ScriptServer.end_use(doc)
	check(doc.sit_state == FurnitureSeating.NOT_SITTING and doc.using == null and _run("DocMitchellREF.GetFurnitureMarkerID") == 0, "leaving the chair stands him (sit state %d)" % doc.sit_state)

	NpcSimulationServer.package_runner.track(doc)
	state.stage = 80
	state.stages_done[80] = true
	NpcSimulationServer.package_runner.evaluate_now(doc)
	await _wait_until(func() -> bool: return doc.package_completed and doc.sit_state == FurnitureSeating.SITTING)
	ScriptServer.apply_pending_moves()
	check(doc.using == chair and doc.sit_state == FurnitureSeating.SITTING and doc.position.distance_to(placement["position"]) < 0.01, "at VCG01 stage 80 his Travel package ends with him seated at the marker (sit state %d, %.2f m off)" % [doc.sit_state, doc.position.distance_to(placement["position"])])

	await _check_on_screen(doc, chair, placement)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Physicalised (NpcController, holding the lease in his house's local
## navigation) with his visual and locomotion loaded: using the chair plays the
## enter idle (sit state 2), then the seated loop (3) with his hips lowered;
## leaving it plays the exit (5), then locomotion again (0). His controller
## stays at the marker throughout.
func _check_on_screen(doc: ActorReference, chair: FurnitureReference, placement: Dictionary) -> void:
	NpcSimulationServer.package_runner.untrack(doc)
	NpcSimulationServer.local_navigation.set_local_cells(doc.current_space_form_id, PackedInt32Array([doc.current_space_form_id]))
	# Seated off screen by his stage 80 package, then physicalised: once his
	# animations load he shows seated (the enter idle from its end, then the
	# seated loop), without sitting down on screen.
	check(doc.sit_state == FurnitureSeating.SITTING, "Doc is seated before he is physicalised (%d)" % doc.sit_state)
	var controller := EsmReferencePhysicaliser.new().physicalise(doc, self) as NpcController
	var animator := controller.actor.animator
	await _wait_until(func() -> bool: return controller.actor.is_visual_built() and _player(controller) != null and _player(controller).current_animation != "", VISUAL_FRAMES)
	check(controller.actor.is_visual_built(), "Doc's visual and locomotion load")
	await _wait_until(func() -> bool: return _idle_name(animator) == "ChairDynamicIdle")
	for frame in 10:
		await get_tree().physics_frame
	check(doc.sit_state == FurnitureSeating.SITTING and _idle_name(animator) == "ChairDynamicIdle", "once loaded he shows seated: the seated loop at sit state 3 (%d, %s)" % [doc.sit_state, _idle_name(animator)])
	check(_hips_height(controller) < 0.7 and _hips_reach(controller) > 0.5, "with his hips low and in the seat (%.2f m high, %.2f m from the marker)" % [_hips_height(controller), _hips_reach(controller)])
	check(_knee_bend(controller) > 60.0, "and his knees bent through the seated loop (left calf %.0f degrees from rest; the enter ends at about 92)" % _knee_bend(controller))
	ScriptServer.end_use(doc)
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.NOT_SITTING)
	for frame in 10:
		await get_tree().physics_frame
	check(_hips_height(controller) > 0.85, "standing up from there ends standing (hips %.2f m)" % _hips_height(controller))
	var standing_hips := _hips_height(controller)
	var standing_turn := _hips_rotation(controller)
	var standing_reach := _hips_reach(controller)
	# The torso's facing relative to the controller, standing in locomotion:
	# added to the controller's heading at the marker, it is how he faces
	# standing there, before the enter idle.
	var standing_offset := angle_difference(_controller_world_yaw(controller), _torso_world_yaw(controller))
	ScriptServer.begin_use(doc, chair)
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.SITTING_DOWN)
	ScriptServer.apply_pending_moves()
	await _wait_until(func() -> bool: return _player(controller).current_animation == ActorAnimator.IDLE_CLIP_NAME)
	check(_idle_name(animator) == "ChairFrontSit" and _player(controller).current_animation == ActorAnimator.IDLE_CLIP_NAME, "sitting down plays ChairFrontSit (%s)" % _idle_name(animator))
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.SITTING)
	for frame in 30:
		await get_tree().physics_frame
	var seated_hips := _hips_height(controller)
	var seated_reach := _hips_reach(controller)
	check(doc.sit_state == FurnitureSeating.SITTING and _idle_name(animator) == "ChairDynamicIdle", "then sit state 3 with the seated loop ChairDynamicIdle (%d, %s)" % [doc.sit_state, _idle_name(animator)])
	check(_knee_bend(controller) > 60.0, "his knees stay bent through the seated loop (left calf %.0f degrees from rest)" % _knee_bend(controller))
	check(seated_hips < standing_hips - 0.25, "his hips are lower seated than standing (%.2f against %.2f m)" % [seated_hips, standing_hips])
	var standing_facing := _controller_world_yaw(controller) + standing_offset
	var seated_turn := rad_to_deg(absf(angle_difference(_torso_world_yaw(controller), standing_facing)))
	check(absf(seated_turn - 180.0) < 20.0, "seated he faces away from the chair: his torso turned %.0f degrees from standing at the marker (180 expected)" % seated_turn)
	check(seated_reach > standing_reach + 0.5, "and carried into the seat, away from the marker (%.2f against %.2f m; the enter KF's root moves 0.78 m)" % [seated_reach, standing_reach])
	var seat := EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * Vector3(placement["position"])
	check(controller.global_position.distance_to(seat) < 0.05, "his controller stays at the marker (%.3f m off)" % controller.global_position.distance_to(seat))
	ScriptServer.end_use(doc)
	check(doc.sit_state == FurnitureSeating.STANDING_UP, "leaving the chair is sit state 5, standing up (%d)" % doc.sit_state)
	await _wait_until(func() -> bool: return _idle_name(animator) == "ChairFrontStand")
	check(_idle_name(animator) == "ChairFrontStand", "standing up plays ChairFrontStand (%s)" % _idle_name(animator))
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.NOT_SITTING)
	for frame in 10:
		await get_tree().physics_frame
	check(doc.sit_state == FurnitureSeating.NOT_SITTING and animator.get_idle() == null and _player(controller).current_animation != ActorAnimator.IDLE_CLIP_NAME, "then sit state 0 and locomotion again (%d, %s)" % [doc.sit_state, _player(controller).current_animation])
	check(controller.global_position.distance_to(seat) < 0.05, "his controller is still at the marker (%.3f m off)" % controller.global_position.distance_to(seat))
	var turned := rad_to_deg(_hips_rotation(controller).angle_to(standing_turn))
	check(turned < 5.0, "back in locomotion his hips sit as they did before sitting (%.1f degrees off)" % turned)
	var stood_turn := rad_to_deg(absf(angle_difference(_torso_world_yaw(controller), standing_facing)))
	check(absf(stood_turn - 180.0) < 20.0, "and he has turned with the stand-up: facing away from the chair, %.0f degrees from before sitting (180 expected)" % stood_turn)

func _player(controller: NpcController) -> AnimationPlayer:
	return controller.find_child(ActorAnimator.PLAYER_NODE_NAME, true, false) as AnimationPlayer

func _idle_name(animator: ActorAnimator) -> String:
	return animator.get_idle().editor_id if animator.get_idle() != null else "none"

## How far Bip01 L Calf is bent from its rest rotation, degrees.
func _knee_bend(controller: NpcController) -> float:
	var skeleton := controller.find_child("Skeleton3D", true, false) as Skeleton3D
	var bone := skeleton.find_bone(NifNamesScript.escape("Bip01 L Calf"))
	return rad_to_deg(skeleton.get_bone_pose_rotation(bone).angle_to(skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()))

## Which way the controller faces in the world (its z axis), radians.
func _controller_world_yaw(controller: NpcController) -> float:
	var axis := controller.global_transform.basis * Vector3.BACK
	return atan2(axis.x, axis.z)

## Which way the torso (Bip01 Spine2's z axis) faces in the world, radians.
func _torso_world_yaw(controller: NpcController) -> float:
	var skeleton := controller.find_child("Skeleton3D", true, false) as Skeleton3D
	var bone := skeleton.find_bone(NifNamesScript.escape("Bip01 Spine2"))
	var axis := (skeleton.global_transform.basis * skeleton.get_bone_global_pose(bone).basis) * Vector3.BACK
	return atan2(axis.x, axis.z)

## Bip01 NonAccum's pose rotation.
func _hips_rotation(controller: NpcController) -> Quaternion:
	var skeleton := controller.find_child("Skeleton3D", true, false) as Skeleton3D
	return skeleton.get_bone_pose_rotation(skeleton.find_bone(NifNamesScript.escape("Bip01 NonAccum")))

## Bip01 NonAccum's horizontal distance from the controller's origin, metres.
func _hips_reach(controller: NpcController) -> float:
	var skeleton := controller.find_child("Skeleton3D", true, false) as Skeleton3D
	var bone := skeleton.find_bone(NifNamesScript.escape("Bip01 NonAccum"))
	var global := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
	var local := controller.global_transform.affine_inverse() * global.origin
	return Vector2(local.x, local.z).length()

## Bip01 NonAccum's height in the controller's space, metres.
func _hips_height(controller: NpcController) -> float:
	var skeleton := controller.find_child("Skeleton3D", true, false) as Skeleton3D
	var bone := skeleton.find_bone(NifNamesScript.escape("Bip01 NonAccum"))
	var global := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
	var local := controller.global_transform.affine_inverse() * global.origin
	return local.y

func _wait_until(condition: Callable, frames := FRAMES) -> void:
	for frame in frames:
		if condition.call():
			return
		await get_tree().physics_frame

func _run(line: String) -> int:
	return int(ScriptServer.run_debug_line(line).get("result", -1))

func _describe(idle: IdleBase) -> String:
	return "%s, %s" % [idle.editor_id, idle.model_path.get_file()] if idle != null else "none"
