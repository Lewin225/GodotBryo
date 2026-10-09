extends Node3D

## The player on Doc Mitchell's couch (Plans/Actors/stage_g.md step 5), and in
## conversation seated and standing (Plans/Actors/head_tracking.md), in the
## running game scene: activating DocMitchellCouchREF seats the possessed
## actor through FurnitureSeating with the furniture idles on the player's
## skeleton; the body holds still in the seat; the camera follows the head
## (camera_mode 1, camera_mount); IsCurrentFurnitureRef holds; interact does
## not get up while movement is disabled (VCG01's test) and does once it is
## enabled; standing returns the camera to camera_mode 0.

const VISUAL_FRAMES := 120 * 60
const FRAMES := 30 * 60
## How far the camera's pitch may be from the pitch to Doc's eyes, degrees: the
## head bone sits below the eyes and the look-at aims from origin_offset.
const PITCH_TOLERANCE_DEGREES := 8.0
## How far Doc's body is raised for the pitch check, metres.
const RAISE_METERS := 4.0

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
	var house := int(EsmServer.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var game: Node3D = (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)
	var player: PlayerController = game.player
	var player_ref: ActorReference = EsmServer.get_player_reference()
	await _wait_until(func() -> bool: return player_ref.current_space_form_id == house and not player.frozen and player.actor != null and player.actor.is_visual_built(), VISUAL_FRAMES)
	await _wait_until(func() -> bool: return _player_animation(player) != "", VISUAL_FRAMES)
	check(player.actor != null and player.actor.is_visual_built(), "the player's actor node is built")
	var couch := EsmServer.find_reference_by_editor_id("DocMitchellCouchREF") as FurnitureReference

	ScriptServer.activate(couch, player_ref)
	await _wait_until(func() -> bool: return player_ref.sit_state == FurnitureSeating.SITTING)
	check(player_ref.using == couch and player_ref.sit_state == FurnitureSeating.SITTING, "activating the couch seats the player (sit state %d)" % player_ref.sit_state)
	check(_run("player.IsCurrentFurnitureRef DocMitchellCouchREF") == 1, "player.IsCurrentFurnitureRef DocMitchellCouchREF is 1")
	var placement := ScriptServer.furniture_seating.get_placement(couch, player_ref.using_marker)
	var seat := EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * Vector3(placement["position"])
	ScriptServer.apply_pending_moves()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var held_at := player.global_position
	for frame in 60:
		await get_tree().physics_frame
	check(Vector2(held_at.x, held_at.z).distance_to(Vector2(seat.x, seat.z)) < 0.05 and player.global_position.distance_to(held_at) < 0.01, "the body is at the couch's marker and holds still (%.3f m from it, moved %.3f m)" % [Vector2(held_at.x, held_at.z).distance_to(Vector2(seat.x, seat.z)), player.global_position.distance_to(held_at)])
	var head = player._head_transform()
	check(player.camera_mode == 1 and head != null and player.camera_mount.global_position.distance_to((head as Transform3D).origin) < 0.3, "the camera follows the head (camera_mode %d, mount %.2f m from the eyes)" % [player.camera_mode, player.camera_mount.global_position.distance_to((head as Transform3D).origin) if head != null else -1.0])
	check(player._head_transform() != null and (player._head_transform() as Transform3D).origin.y < held_at.y + 1.3, "seated, the head is low (%.2f m above the feet)" % ((player._head_transform() as Transform3D).origin.y - held_at.y if player._head_transform() != null else -1.0))

	# In conversation with Doc the player's head tracking turns the head to
	# him, and the seated camera, following the head, turns with it.
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var doc_eyes := _eyes_of(doc)
	var before := _camera_angle_to(player, doc_eyes)
	DialogueServer._conversation_speaker = doc
	DialogueServer._conversation_listener = player_ref
	for frame in 150:
		await get_tree().process_frame
	var during := _camera_angle_to(player, _eyes_of(doc))
	var seated_short := _short_of_limit(player)
	check(player.actor.head_tracking.get_target() == doc and absf(during - seated_short) < 3.0, "in conversation with Doc the seated camera turns to him as far as the neck allows (%.0f degrees off, from %.0f; %.0f beyond the left-right limit)" % [during, before, seated_short])
	var seated_pitch := _camera_pitch_off(player, _eyes_of(doc))
	check(absf(seated_pitch.x - seated_pitch.y) < PITCH_TOLERANCE_DEGREES, "and pitches up or down to his eyes (camera %.0f degrees, his eyes %.0f)" % [seated_pitch.x, seated_pitch.y])
	DialogueServer._conversation_speaker = null
	DialogueServer._conversation_listener = null

	ScriptServer.disable_player_controls(ScriptServer.CONTROL_MOVEMENT)
	player._unhandled_input(_interact())
	check(player_ref.sit_state == FurnitureSeating.SITTING, "with movement disabled, interact does not get up")
	ScriptServer.enable_player_controls(ScriptServer.CONTROL_MOVEMENT)
	player._unhandled_input(_interact())
	check(player_ref.sit_state == FurnitureSeating.STANDING_UP and player_ref.using == null, "with movement enabled, interact gets up (sit state %d)" % player_ref.sit_state)
	await _wait_until(func() -> bool: return player_ref.sit_state == FurnitureSeating.NOT_SITTING)
	await get_tree().process_frame
	check(player_ref.sit_state == FurnitureSeating.NOT_SITTING and player.camera_mode == 0, "standing up returns the camera to camera_mode 0 (%d)" % player.camera_mode)

	# Walking into a conversation: the conversation screen suspends input, and
	# the body reports standing still rather than its last step.
	player.motion.move_input = Vector2(0.0, 1.0)
	player.motion.velocity = Vector3(0.0, 0.0, -3.0)
	player._on_conversation_started(doc, player_ref)
	check(player.motion.move_input == Vector2.ZERO and player.motion.velocity == Vector3.ZERO, "entering a conversation while walking stills the body's motion (input %s, velocity %s)" % [player.motion.move_input, player.motion.velocity])
	player._on_conversation_ended(doc)

	# Standing, in conversation with Doc: the camera follows the head too.
	var standing_before := _camera_angle_to(player, _eyes_of(doc))
	DialogueServer._conversation_speaker = doc
	DialogueServer._conversation_listener = player_ref
	for frame in 150:
		await get_tree().process_frame
	var standing_during := _camera_angle_to(player, _eyes_of(doc))
	var standing_short := _short_of_limit(player)
	check(player.camera_mode == 1 and absf(standing_during - standing_short) < 3.0, "standing in conversation with Doc the camera follows the head to him as far as the neck allows (camera_mode %d, %.0f degrees off, from %.0f; %.0f beyond the left-right limit)" % [player.camera_mode, standing_during, standing_before, standing_short])
	var standing_pitch := _camera_pitch_off(player, _eyes_of(doc))
	check(absf(standing_pitch.x - standing_pitch.y) < PITCH_TOLERANCE_DEGREES, "and pitches up or down to his eyes (camera %.0f degrees, his eyes %.0f)" % [standing_pitch.x, standing_pitch.y])
	# Doc's body raised (he stands about 15 m away): the camera pitches up
	# to his eyes.
	var doc_body := (EsmNode.node_for(doc) as NpcController).actor
	doc_body.position.y += RAISE_METERS
	for frame in 150:
		await get_tree().process_frame
	var raised_pitch := _camera_pitch_off(player, _eyes_of(doc))
	check(raised_pitch.y > standing_pitch.y + 10.0 and absf(raised_pitch.x - raised_pitch.y) < PITCH_TOLERANCE_DEGREES, "with Doc raised %.0f m the camera pitches up to his eyes (camera %.0f degrees, his eyes %.0f)" % [RAISE_METERS, raised_pitch.x, raised_pitch.y])
	doc_body.position.y -= RAISE_METERS
	DialogueServer._conversation_speaker = null
	DialogueServer._conversation_listener = null
	await get_tree().process_frame
	check(player.camera_mode == 0, "and returns to the free camera when it ends (%d)" % player.camera_mode)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Doc's eyes: his ActorHeadTracking's head when he has a node, else his
## position plus eye height.
func _eyes_of(actor: ActorReference) -> Vector3:
	var node := EsmNode.node_for(actor) as NpcController
	if node != null and node.actor != null and node.actor.head_tracking != null:
		return node.actor.head_tracking.get_eye_position()
	return EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * actor.position + Vector3.UP * 1.6

## How far, horizontally, the camera's forward is from the direction to
## `point`, degrees.
func _camera_angle_to(player: PlayerController, point: Vector3) -> float:
	var forward := -player.camera_mount.global_basis.z
	var to_point := point - player.camera_mount.global_position
	return rad_to_deg(absf(Vector2(forward.x, forward.z).angle_to(Vector2(to_point.x, to_point.z))))

## The camera's pitch and the pitch from the camera to `point`, degrees, up
## positive: x the camera's, y the point's.
func _camera_pitch_off(player: PlayerController, point: Vector3) -> Vector2:
	var forward := -player.camera_mount.global_basis.z
	var to_point := (point - player.camera_mount.global_position).normalized()
	return Vector2(rad_to_deg(asin(forward.y)), rad_to_deg(asin(to_point.y)))

## How far the look point lies beyond the head's left-right limit, degrees (0
## when within it): the angle about the head bone's X axis from its rest pose
## under the animated neck, which LookAtModifier3D limits, less half the range.
func _short_of_limit(player: PlayerController) -> float:
	var skeleton := player.actor.find_child("Skeleton3D", true, false) as Skeleton3D
	var bone := skeleton.find_bone(ActorHeadTracking.HEAD_BONE_NAME)
	var rest := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.get_bone_parent(bone)) * skeleton.get_bone_rest(bone)
	var local := rest.basis.inverse() * (_look_point(player) - rest.origin)
	var turn := rad_to_deg(absf(Vector2(local.y, local.z).angle_to(Vector2.RIGHT)))
	return maxf(0.0, turn - player.actor.head_tracking.left_right_limit_degrees * 0.5)

## Where the player's head tracking aims (its Look Point).
func _look_point(player: PlayerController) -> Vector3:
	return (player.actor.find_child(ActorHeadTracking.AIM_NODE_NAME, true, false) as Node3D).global_position

func _interact() -> InputEventAction:
	var event := InputEventAction.new()
	event.action = &"interact"
	event.pressed = true
	return event

func _player_animation(player: PlayerController) -> String:
	var animation_player := player.find_child(ActorAnimator.PLAYER_NODE_NAME, true, false) as AnimationPlayer
	return animation_player.current_animation if animation_player != null else ""

func _run(line: String) -> int:
	return int(ScriptServer.run_debug_line(line).get("result", -1))

func _wait_until(condition: Callable, frames := FRAMES) -> void:
	for frame in frames:
		if condition.call():
			return
		await get_tree().physics_frame
