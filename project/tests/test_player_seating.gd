extends Node3D

## The player on Doc Mitchell's couch (Plans/Actors/stage_g.md step 5), in the
## running game scene: activating DocMitchellCouchREF seats the possessed
## actor through FurnitureSeating with the furniture idles on the player's
## skeleton; the body holds still in the seat; the camera follows the head
## (camera_mode 1, camera_mount); IsCurrentFurnitureRef holds; interact does
## not get up while movement is disabled (VCG01's test) and does once it is
## enabled; standing returns the camera to camera_mode 0.

const VISUAL_FRAMES := 120 * 60
const FRAMES := 30 * 60

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

	ScriptServer.disable_player_controls(ScriptServer.CONTROL_MOVEMENT)
	player._unhandled_input(_interact())
	check(player_ref.sit_state == FurnitureSeating.SITTING, "with movement disabled, interact does not get up")
	ScriptServer.enable_player_controls(ScriptServer.CONTROL_MOVEMENT)
	player._unhandled_input(_interact())
	check(player_ref.sit_state == FurnitureSeating.STANDING_UP and player_ref.using == null, "with movement enabled, interact gets up (sit state %d)" % player_ref.sit_state)
	await _wait_until(func() -> bool: return player_ref.sit_state == FurnitureSeating.NOT_SITTING)
	await get_tree().process_frame
	check(player_ref.sit_state == FurnitureSeating.NOT_SITTING and player.camera_mode == 0, "standing up returns the camera to camera_mode 0 (%d)" % player.camera_mode)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

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
