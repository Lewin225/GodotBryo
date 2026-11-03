extends Node

## Boots game.tscn straight into an exterior, with no interior first: a new
## game whose start location is outside Doc Mitchell's front door
## (game.gd's start_location). WorldStreamerV2 activates with no earlier space,
## TerrainStreamer's first ready wait completes, the body is placed and
## released, and the exterior environment, weather and sky are on.

const TIMEOUT_MSEC := 120000
const GameScript := preload("res://game.gd")

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var house := int(EsmServer.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var wasteland := int(EsmServer.reader.find_worldspace_by_editor_id("WastelandNV").get("form_id", 0))
	var front_door: DoorReference = null
	for reference in EsmServer.get_references_in_cell(house):
		if reference is DoorReference and reference.has_teleport and reference.get_teleport_destination_space_form_id() == wasteland:
			front_door = reference
	check(front_door != null, "Doc Mitchell's house has a door to WastelandNV")
	if front_door == null:
		_finish()
		return
	GameScript.start_location = {"space_form_id": wasteland, "position": front_door.teleport_position, "rotation": front_door.teleport_rotation}

	var game: Node3D = (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)
	var coordinator: TransitionCoordinator = game.transition_coordinator
	var player: PlayerController = game.player
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while (coordinator.loaded_space_form_id != wasteland or coordinator.is_transitioning()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	for _frame in 3:
		await get_tree().physics_frame
	var player_ref := EsmServer.get_player_reference()
	check(coordinator.loaded_space_form_id == wasteland and not coordinator.is_transitioning(), "the game boots into WastelandNV")
	check(player_ref.current_space_form_id == wasteland, "the player's reference is in WastelandNV")
	check(EsmReferencePhysicaliser.authored_position(player.global_position).distance_to(front_door.teleport_position) < 0.5, "the body stands at the start location")
	check(not player.frozen, "the body is released")
	var tile_root: Node3D = game.world_streamer._resident.get(EsmServer.exterior_grid_coord(player_ref.position))
	check(tile_root != null, "WorldStreamerV2 has the player's tile resident")
	check(game.sun.visible and game.world_environment.environment != game.INTERIOR_ENVIRONMENT, "the exterior environment is active")
	check(not game.weather_manager.weather_to.is_empty() and not game.weather_manager.climate.is_empty(), "WastelandNV's climate and a weather are set")
	_finish()

func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)
