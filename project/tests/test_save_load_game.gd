extends Node

## Saving in game and loading in a fresh process, as from the launcher. Runs
## in one of three phases, from SAVE_LOAD_PHASE:
## - `save`: a new game in Doc Mitchell's house; the player steps aside, the
##   house's back door opens, VCG01 reaches stage 10, a stimpak goes in a
##   container and the hour changes; saves `inside`; then the player goes out
##   through the front door; saves `outside`. Writes what it saved to
##   expected.json beside the saves.
## - `load_inside` and `load_outside`: boots game.tscn with that save
##   (game.gd's load_save_id) and checks the player, the quest stage, the
##   door, the container, Sunny Smiles' package and position, the time and,
##   outside, the weather and the exterior's terrain and sky.
## Saves go to user://test_saves. Run the three phases in that order:
##   SAVE_LOAD_PHASE=save ...; SAVE_LOAD_PHASE=load_inside ...; SAVE_LOAD_PHASE=load_outside ...

const GameScript := preload("res://game.gd")
const ROOT := "user://test_saves"
const TIMEOUT_MSEC := 120000

var failures := 0
var game: Node3D

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	SaveServer.register_backend("json_folder", JsonFolderBackend.new(ROOT))
	var phase := OS.get_environment("SAVE_LOAD_PHASE")
	match phase:
		"save":
			await _save_phase()
		"load_inside":
			await _load_phase("inside")
		"load_outside":
			await _load_phase("outside")
		_:
			check(false, "SAVE_LOAD_PHASE is save, load_inside or load_outside (got '%s')" % phase)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _save_phase() -> void:
	var house := _house()
	_start_game()
	check(await _await_space(house), "a new game loads Doc Mitchell's house")
	var player_ref := EsmServer.get_player_reference()
	var expected := {}

	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01")
	QuestServer.set_stage(vcg01, 10)
	var back_door := EsmServer.get_reference_by_form_id(0x0010901D) as DoorReference
	back_door.is_open = not back_door.is_open
	var container := _first_container_in(house)
	container.contents.add_item(EsmServer.find_base_by_editor_id("Stimpak").form_id, null, 3)
	game.game_time_manager.set_hour(21.5)
	game.player.global_position += Vector3(0.75, 0.0, 0.0)
	for _frame in 3:
		await get_tree().physics_frame
	expected["inside"] = _snapshot(container, back_door)
	check(SaveServer.save("inside") == OK, "saving inside the house: %s" % ", ".join(SaveServer.report))

	var front_door := _front_door(house)
	ScriptServer.activate(front_door, player_ref)
	check(await _await_space(front_door.get_teleport_destination_space_form_id()), "the front door loads WastelandNV")
	for _frame in 30:
		await get_tree().process_frame
	expected["outside"] = _snapshot(container, back_door)
	expected["outside"]["weather_to"] = int(game.weather_manager.weather_to.get("form_id", 0))
	check(SaveServer.save("outside", "inside") == OK, "saving outside: %s" % ", ".join(SaveServer.report))
	var file := FileAccess.open(ROOT.path_join("expected.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(expected, "\t", true))
	file.close()

func _load_phase(save_id: String) -> void:
	var expected_all: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ROOT.path_join("expected.json")))
	var expected: Dictionary = expected_all[save_id]
	GameScript.load_save_id = save_id
	_start_game()
	var space := int(expected["player_space"])
	check(await _await_space(space), "loading %s puts the player's space around them" % save_id)
	var player_ref := EsmServer.get_player_reference()
	check(game.player.possessed == player_ref, "the controller possesses the loaded player's reference")
	check(player_ref.position.distance_to(_vector(expected["player_position"])) < 0.05, "the player is where they were saved (%s)" % player_ref.position)
	check(EsmReferencePhysicaliser.authored_position(game.player.global_position).distance_to(_vector(expected["player_position"])) < 0.5, "the body stands there")
	check(not game.player.frozen, "the body is released")
	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01")
	check(QuestServer.get_stage(vcg01) >= 10 and QuestServer.active_quest == vcg01,
			"VCG01 is at stage 10 or past it and the active quest (stage %d, active %s)" % [QuestServer.get_stage(vcg01), QuestServer.active_quest.editor_id if QuestServer.active_quest != null else "none"])
	var back_door := EsmServer.get_reference_by_form_id(0x0010901D) as DoorReference
	check(back_door.is_open == bool(expected["back_door_open"]), "the back door is as it was")
	var container := EsmServer.get_reference_by_form_id(int(expected["container"])) as ContainerReference
	check(container.contents.get_item_count(EsmServer.find_base_by_editor_id("Stimpak").form_id) == int(expected["container_stimpaks"]), "the container holds the stimpaks put in it")
	var sunny := EsmServer.find_reference_by_editor_id("SunnyREF") as ActorReference
	var sunny_package: Variant = sunny.active_package.form_id if sunny.active_package != null else 0
	check(int(sunny_package) == int(expected["sunny_package"]) or int(expected["sunny_package"]) == 0, "Sunny's package is the saved one")
	check(sunny.position.distance_to(_vector(expected["sunny_position"])) < 15.0, "Sunny is near where she was saved (%.1f m)" % sunny.position.distance_to(_vector(expected["sunny_position"])))
	check(absf(game.game_time_manager.game_hour - float(expected["game_hour"])) < 0.1, "the time is as saved (%.2f)" % game.game_time_manager.game_hour)
	if save_id == "outside":
		check(int(game.weather_manager.weather_to.get("form_id", 0)) == int(expected["weather_to"]), "the weather is as saved")
		check(game.sun.visible and game.world_environment.environment != game.INTERIOR_ENVIRONMENT, "the exterior environment is active")
		var tile_root: Node3D = game.world_streamer._resident.get(EsmServer.exterior_grid_coord(player_ref.position))
		check(tile_root != null, "the player's exterior tile is resident")
	else:
		check(not game.sun.visible, "the interior environment is active")

func _start_game() -> void:
	game = (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)

func _snapshot(container: ContainerReference, back_door: DoorReference) -> Dictionary:
	var player_ref := EsmServer.get_player_reference()
	var sunny := EsmServer.find_reference_by_editor_id("SunnyREF") as ActorReference
	var position := player_ref.position
	return {
		"player_space": player_ref.current_space_form_id,
		"player_position": [position.x, position.y, position.z],
		"back_door_open": back_door.is_open,
		"container": EsmServer.form_id_for_instance_id(container.instance_id),
		"container_stimpaks": container.contents.get_item_count(EsmServer.find_base_by_editor_id("Stimpak").form_id),
		"sunny_package": sunny.active_package.form_id if sunny.active_package != null else 0,
		"sunny_position": [sunny.position.x, sunny.position.y, sunny.position.z],
		"game_hour": game.game_time_manager.game_hour,
	}

func _await_space(space_form_id: int) -> bool:
	var coordinator: TransitionCoordinator = game.transition_coordinator
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while (coordinator.loaded_space_form_id != space_form_id or coordinator.is_transitioning()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	for _frame in 3:
		await get_tree().physics_frame
	return coordinator.loaded_space_form_id == space_form_id

func _house() -> int:
	return int(EsmServer.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))

func _front_door(house: int) -> DoorReference:
	var wasteland := int(EsmServer.reader.find_worldspace_by_editor_id("WastelandNV").get("form_id", 0))
	for reference in EsmServer.get_references_in_cell(house):
		if reference is DoorReference and reference.has_teleport and not reference.is_locked and reference.get_teleport_destination_space_form_id() == wasteland:
			return reference
	return null

func _first_container_in(cell: int) -> ContainerReference:
	for reference in EsmServer.get_references_in_cell(cell):
		if reference is ContainerReference:
			return reference
	return null

func _vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])
